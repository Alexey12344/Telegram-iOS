#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <LegacyComponents/LegacyComponentsContext.h>

@class TGViewController;
@class TGMenuSheetController;
@class TGMediaAssetsController;
@class TGVideoEditAdjustments;

@protocol TGPhotoPaintStickersContext;

typedef void (^TGMediaAvatarPresentImpl)(id<LegacyComponentsContext>, void (^)(UIViewController *));

@interface TGMediaAvatarMenuMixin : NSObject

@property (nonatomic, assign) bool forceDark;

@property (nonatomic, copy) void (^willFinishWithImage)(UIImage *image, void (^)(void));
@property (nonatomic, copy) void (^willFinishWithVideo)(UIImage *image, void (^)(void));

@property (nonatomic, copy) void (^didFinishWithImage)(UIImage *image);
@property (nonatomic, copy) void (^didFinishWithVideo)(UIImage *image, AVAsset *asset, TGVideoEditAdjustments *adjustments);
@property (nonatomic, copy) void (^didFinishWithDelete)(void);
@property (nonatomic, copy) void (^didFinishWithView)(void);
@property (nonatomic, copy) void (^didDismiss)(void);
@property (nonatomic, copy) void (^requestSearchController)(TGMediaAssetsController *);
@property (nonatomic, copy) CGRect (^sourceRect)(void);

@property (nonatomic, copy) void (^requestAvatarEditor)(void (^)(UIImage *image, void(^commit)(void)), void (^)(UIImage *image, NSURL *asset, id adjustments, id markup, void(^commit)(void)));

@property (nonatomic, strong) id<TGPhotoPaintStickersContext> stickersContext;

- (instancetype)initWithContext:(id<LegacyComponentsContext>)context parentController:(TGViewController *)parentController hasDeleteButton:(bool)hasDeleteButton saveEditedPhotos:(bool)saveEditedPhotos saveCapturedMedia:(bool)saveCapturedMedia;
- (instancetype)initWithContext:(id<LegacyComponentsContext>)context parentController:(TGViewController *)parentController hasDeleteButton:(bool)hasDeleteButton personalPhoto:(bool)personalPhoto saveEditedPhotos:(bool)saveEditedPhotos saveCapturedMedia:(bool)saveCapturedMedia;
- (instancetype)initWithContext:(id<LegacyComponentsContext>)context parentController:(TGViewController *)parentController hasSearchButton:(bool)hasSearchButton hasDeleteButton:(bool)hasDeleteButton hasViewButton:(bool)hasViewButton personalPhoto:(bool)personalPhoto isVideo:(bool)isVideo saveEditedPhotos:(bool)saveEditedPhotos saveCapturedMedia:(bool)saveCapturedMedia signup:(bool)signup forum:(bool)forum title:(NSString *)title isSuggesting:(bool)isSuggesting;
- (TGMenuSheetController *)present;

@end
