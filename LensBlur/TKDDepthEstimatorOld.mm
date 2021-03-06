//
//  TKDDepthEstimatorOld.m
//  LensBlur
//
//  Created by 武田 祐一 on 2014/08/10.
//  Copyright (c) 2014年 Yuichi Takeda. All rights reserved.
//

#import "TKDDepthEstimatorOld.h"
#import <opencv.hpp>
#include "depth_from_sequence.hpp"
#import <ios.h>

NSString *TKDDepthEstimatorOldErrorDomain = @"tkd.depthEstimator.error";
static int const kMaxImages = 12;

using namespace std;
using namespace cv;

@interface TKDDepthEstimatorOld ()
{
    vector<Mat3b> *full_color_images;
    FeatureTracker *tracker;
}
@property (nonatomic, strong) dispatch_queue_t queue;
@property (atomic) BOOL running;
@property NSFileHandle *pipeReadHandle;

// processing status
@property (nonatomic, assign) int trackingPoints;
@property (nonatomic, assign) int bundleAdjustmentIttr;
@property (nonatomic, assign) double reprojectionError;

// parameters
@property (nonatomic, assign, readonly) cv::Rect roi;

@end

@implementation TKDDepthEstimatorOld
- (instancetype)initWithImageSize:(CGSize)size roi:(CGRect)roi {
    self = [self init];
    if (self) {
        full_color_images = new vector<Mat3b>;
        tracker = new FeatureTracker;
        tracker->MAX_IMAGES = kMaxImages;
        _queue = dispatch_queue_create("DepthEstimationQueue", DISPATCH_QUEUE_SERIAL);
        _roi = cv::Rect(roi.origin.x, roi.origin.y, roi.size.width, roi.size.height);
        _depthResolution = 32;
        self.log = [NSMutableString string];
    }
    return self;
}

- (void)dealloc {
    delete full_color_images;
    self.captureLog = NO;
}

- (void)setCaptureLog:(BOOL)captureLog {
    if (_captureLog != captureLog) {
        [self willChangeValueForKey:@"captureLog"];
        _captureLog = captureLog;
        [self didChangeValueForKey:@"captureLog"];

        if (captureLog) {
            NSPipe *pipe = [NSPipe pipe];
            self.pipeReadHandle = [pipe fileHandleForReading];
            dup2([[pipe fileHandleForWriting] fileDescriptor], fileno(stdout));
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(readSTDOUT:) name:NSFileHandleReadCompletionNotification object:nil];
            [self.pipeReadHandle readInBackgroundAndNotify];
        } else {
            [[NSNotificationCenter defaultCenter] removeObserver:self];
            dup2(fileno(stdout), self.pipeReadHandle.fileDescriptor);
        }
    }
}

- (NSInteger)numberOfRquiredImages {
    return kMaxImages - full_color_images->size();
}

- (NSDictionary *)computationLog {
    return @{@"reprojection_error": @(self.reprojectionError),
             @"bundl_adjustment_ittr": @(self.bundleAdjustmentIttr),
             @"tracking_points": @(self.trackingPoints),
             };
}

- (UIImage *)referenceImage {
    Mat3b mat(full_color_images->front().size());
    full_color_images->front()(_roi).copyTo(mat);
    UIImage *img = MatToUIImage(mat);
    return [UIImage imageWithCGImage:img.CGImage scale:1.0 orientation:UIImageOrientationRight];
}

+ (Mat3b)sampleBufferToMat:(CMSampleBufferRef)sampleBuffer {
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);

    CVPixelBufferLockBaseAddress( pixelBuffer, 0 );

    //Processing here
    int bufferWidth = (int)CVPixelBufferGetWidth(pixelBuffer);
    int bufferHeight = (int)CVPixelBufferGetHeight(pixelBuffer);
    unsigned char *pixel = (unsigned char *)CVPixelBufferGetBaseAddress(pixelBuffer);

    // put buffer in open cv, no memory copied
    Mat4b mat = cv::Mat(bufferHeight,bufferWidth,CV_8UC4,pixel);
    Mat3b mat3b(bufferHeight, bufferWidth);
    cvtColor(mat, mat3b, CV_BGRA2RGB);

    //End processing
    CVPixelBufferUnlockBaseAddress( pixelBuffer, 0 );

    return mat3b;
}

- (NSArray *)convertToUIImages {
    NSMutableArray *array = [NSMutableArray array];
    for (int i = 0; i < full_color_images->size(); ++i) {
        Mat3b mat = (*full_color_images)[i];
        UIImage *img = MatToUIImage(mat);
        [array addObject:[UIImage imageWithCGImage:img.CGImage scale:1.0 orientation:UIImageOrientationRight]];
    }
    return array;
}

- (void)readSTDOUT:(NSNotification *)n {
    [self.pipeReadHandle readInBackgroundAndNotify];
    NSString *str = [[NSString alloc] initWithData:n.userInfo[NSFileHandleNotificationDataItem] encoding:NSASCIIStringEncoding];
    [self.log appendString:str];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate depthEstimator:self getLog:self.log];
    });

}

- (void)checkStability:(CMSampleBufferRef)sampleBuffer
                 block:(void (^)(CGFloat))block
{
    Mat3b mat = [[self class] sampleBufferToMat:sampleBuffer];
    dispatch_async(_queue, ^{
        Mat1b *gray = new Mat1b(mat.size());
        cvtColor(mat, *gray, CV_RGB2GRAY);
        int features = tracker->good_features_to_track(*gray);
        dispatch_async(dispatch_get_main_queue(), ^{
            CGFloat st = (CGFloat)features/(CGFloat)tracker->MAX_CORNERS;
            if (block) block(st);
        });
        delete gray;
    });
}


- (void)addImage:(CMSampleBufferRef)sampleBuffer block:(void (^)(BOOL, BOOL))block
{
    Mat3b new_image = [[self class] sampleBufferToMat:sampleBuffer];

    dispatch_async(_queue, ^{

        if (full_color_images->size() >= kMaxImages) {
            if (block) block(NO, YES);
            return;
        }

        Mat1b *gray = new Mat1b(new_image.size());
        cvtColor(new_image, *gray, CV_BGR2GRAY);
        bool added = tracker->add_image(*gray);

        if (added) {
            full_color_images->push_back(new_image);
            cout << tracker->count_track_points() << endl;
        }

        if (block) {
            BOOL prepared = (full_color_images->size() >= kMaxImages);
            block(added, prepared);
        }

        delete gray;
    });
}

- (void)runEstimationOnSuccess:(void (^)(UIImage *))onSuccess
                    onProgress:(void (^)(CGFloat))onProgress
                       onError:(void (^)(NSError *))onError
{
    if (self.running == NO) {
        self.running = YES;

        dispatch_async(_queue, ^{
            [self runEstimationImplOnSuccess:^(UIImage *image) {
                self.running = NO;
                dispatch_async(dispatch_get_main_queue(), ^{
                    onSuccess(image);
                });
            } onProgress:^(CGFloat fraction) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    onProgress(fraction);
                });
            } onError:^(NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    onError(error);
                });
            }];
        });
    } else {
        NSError *error = [NSError errorWithDomain:TKDDepthEstimatorOldErrorDomain
                                             code:TKDDepthEstimatorOldAlredyRunning
                                         userInfo:nil];
        onError(error);
    }

}

- (void)runEstimationImplOnSuccess:(void (^)(UIImage *))onSuccess
                        onProgress:(void (^)(CGFloat))onProgress
                           onError:(void (^)(NSError *))onError
{
    CGFloat unitPerBAItter = 20; // BundleAdjustment一回あたりの進み具合
    CGFloat baComputationUnit = 5 * unitPerBAItter; // MAX_ITRR * unitPerIttr
    CGFloat psComputationUnit = full_color_images->front().rows;
    CGFloat totalUnit = baComputationUnit + psComputationUnit;

    // feature trackingの結果を得る
    vector< vector<Point2d> > track_points = tracker->pickup_stable_points();

    // Solver を初期化
    BundleAdjustment::Solver solver( track_points );
    double min_depth = 500.0; // [mm]
    double fov = 55.0; // [deg]
    cv::Size img_size = full_color_images->front().size();
    double f = MIN(img_size.width, img_size.height)/2.0;
    solver.initialize(track_points, min_depth, fov, img_size, f);

    // bundle adjustment を実行
    while ( solver.should_continue ) {
        solver.run_one_step();
        onProgress(unitPerBAItter * (solver.ittr+1)/totalUnit);
        print_ittr_status(solver);
    }

    onProgress(baComputationUnit/totalUnit); // complate ba_coputation

    if (solver.good_reporjection() == false) {
        NSError *error = [NSError errorWithDomain:TKDDepthEstimatorOldErrorDomain
                                             code:TKDDepthEstimatorOldBundleAdjustmentFailed
                                         userInfo:nil];
        onError(error);
        return;
    }


    // plane sweep の準備
    vector<double> depths = solver.depth_variation(self.depthResolution);

    // plane sweep + dencecrf で奥行きを求める
    PlaneSweep *ps = new PlaneSweep(*full_color_images, solver.camera_params, depths, _roi);
    ps->sweep(full_color_images->front()); // ref imageは最初の画像
    onProgress(1.0);

    UIImage *raw = MatToUIImage(ps->_depth_raw);
    self.rawDepthMap = [UIImage imageWithCGImage:raw.CGImage scale:1.0
                                     orientation:UIImageOrientationRight];

    UIImage *smooth = MatToUIImage(ps->_depth_smooth);
    self.smoothDepthMap = [UIImage imageWithCGImage:smooth.CGImage scale:1.0
                                        orientation:UIImageOrientationRight];

    self.bundleAdjustmentIttr = solver.ittr;
    self.reprojectionError = solver.reprojection_error();
    self.trackingPoints = solver.Np;

    onSuccess(self.smoothDepthMap);
    
    delete ps;

}

@end
