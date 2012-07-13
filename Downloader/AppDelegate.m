/****************************************************************************
 * AppDelegate.m                                                            *
 * Created by Alexander Skobelev                                            *
 *                                                                          *
 ****************************************************************************/

#import "AppDelegate.h"
#import "CommonUtils.h"
#import <AFNetworking.h>
#import <CommonCrypto/CommonDigest.h>
#import "DownloadManager.h"

#define DFNLOG(FMT$, ARGS$...) fprintf (stderr, "%s\n", [STRF(FMT$, ##ARGS$) UTF8String])
// #define DFNLOG(FMT$, ARGS$...) NSLog (@"%s -- " FMT$, __PRETTY_FUNCTION__, ##ARGS$)

//============================================================================
@interface AppDelegate ()

@property (strong, nonatomic) DownloadManager* dmgr;
@property (strong, nonatomic) NSURL* currentURL;
@end

//============================================================================
@implementation AppDelegate 

@synthesize window = _window;
@synthesize dmgr = dmgr_;
@synthesize currentURL = _currentURL;

//----------------------------------------------------------------------------
- (NSURL*) fileURL
{
    STATIC (_s_url, [NSURL URLWithString: @"https://s3-eu-west-1.amazonaws.com/izi-testing/50.bin"]);
    // STATIC (_s_url, [NSURL URLWithString: @"https://s3-eu-west-1.amazonaws.com/izi-packages/d031fbd9-8942-4168-96ea-914a8a1d3f98.tar.gz"]);
    return _s_url;
}

//----------------------------------------------------------------------------
- (NSString*) downloadPath
{
    STATIC (_s_path, user_documents_path());
    return _s_path;
}

//----------------------------------------------------------------------------
- (BOOL) startDownload: (NSString*) file
     completionHandler: (void (^)(NSError* err)) completionHandler
         updateHandler: (void (^)(size_t downloaded, size_t expected)) updateHandler
{
    NSURL* url = nil;
    if ([file hasPrefix: @"http"])
    {
        url = [NSURL URLWithString: file];
    }
    else if (file.length)
    {
        url = [[NSURL alloc]
                  initWithScheme: [self.fileURL scheme]
                            host: [self.fileURL host]
                            path: STR_ADDPATH ([[self.fileURL path] stringByDeletingLastPathComponent], file)];
    }
    else {
        url = self.fileURL;
    }
    
    if (! url)
    {
        DFNLOG(@"ERROR: Failed to create URL for file \"%@\"", file);
        return NO;
    }


    NSString* fname = [[url path] lastPathComponent];
    NSString* filepath = STR_ADDPATH (self.downloadPath, fname);

    
    if ([self.dmgr downloadFileAtURL: url 
                              toPath: filepath 
                   completionHandler: completionHandler 
                       updateHandler: updateHandler])
    {
        self.currentURL = url;
        return YES;
    }
    return NO;
}

//----------------------------------------------------------------------------
- (void) stopDownload
{
    if (self.currentURL) {
        [self.dmgr cancelOperationForURL: self.currentURL];
        self.currentURL = nil;
    }
}

//----------------------------------------------------------------------------
- (void) resetDownload
{
    unlink (STR_FSREP ([self.fileURL path]));
}

//----------------------------------------------------------------------------
- (BOOL) application: (UIApplication*) application
didFinishLaunchingWithOptions: (NSDictionary*) launchOptions
{
    // Override point for customization after application launch.
    self.dmgr = [DownloadManager new];
    return YES;
}
							
//----------------------------------------------------------------------------
- (void) applicationWillResignActive: (UIApplication*) application
{
    // Sent when the application is about to move from active to inactive
    // state. This can occur for certain types of temporary interruptions
    // (such as an incoming phone call or SMS message) or when the user quits
    // the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle
    // down OpenGL ES frame rates. Games should use this method to pause the
    // game.
}

//----------------------------------------------------------------------------
- (void) applicationDidEnterBackground: (UIApplication*) application
{
    // Use this method to release shared resources, save user data, invalidate
    // timers, and store enough application state information to restore your
    // application to its current state in case it is terminated later.  If
    // your application supports background execution, this method is called
    // instead of applicationWillTerminate: when the user quits.
}

//----------------------------------------------------------------------------
- (void) applicationWillEnterForeground: (UIApplication*) application
{
    // Called as part of the transition from the background to the inactive
    // state; here you can undo many of the changes made on entering the
    // background.
}

//----------------------------------------------------------------------------
- (void) applicationDidBecomeActive: (UIApplication*) application
{
    // Restart any tasks that were paused (or not yet started) while the
    // application was inactive. If the application was previously in the
    // background, optionally refresh the user interface.
}

//----------------------------------------------------------------------------
- (void) applicationWillTerminate: (UIApplication*) application
{
    // Called when the application is about to terminate. Save data if
    // appropriate. See also applicationDidEnterBackground:.
}

@end
