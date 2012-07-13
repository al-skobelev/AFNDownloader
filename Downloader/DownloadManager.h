/****************************************************************************
 * DownloadManager.h                                                        *
 * Created by Alexander Skobelev                                            *
 *                                                                          *
 ****************************************************************************/
#import <UIKit/UIKit.h>

//============================================================================
@interface DownloadManager : NSObject

- (void) cancelOperationForURL: (NSURL*) url;

- (BOOL) downloadFileAtURL: (NSURL*) url
                    toPath: (NSString*) filepath
         completionHandler: (void (^)(NSError* err)) completionHandler
             updateHandler: (void (^)(size_t downloaded, size_t expected)) updateHandler;

@end

/* EOF */
