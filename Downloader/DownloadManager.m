/****************************************************************************
 * DownloadManager.m                                                        *
 * Created by Alexander Skobelev                                            *
 *                                                                          *
 ****************************************************************************/

#import "DownloadManager.h"
#import <AFNetworking.h>
#import <CommonCrypto/CommonDigest.h>
#import "CommonUtils.h"

#define DMGR_QUEUE_NAME @"com.iziteq.downloadmanager.queue"

#define DFNLOG(FMT$, ARGS$...) fprintf (stderr, "%s\n", [STRF(FMT$, ##ARGS$) UTF8String])
// #define DFNLOG(FMT$, ARGS$...) NSLog (@"%s -- " FMT$, __PRETTY_FUNCTION__, ##ARGS$)

//============================================================================
@interface AFHTTPRequestOperation (SuperPrivateMethods)

- (void) connection: (NSURLConnection*) connection 
 didReceiveResponse: (NSURLResponse*) response;

- (void) connection: (NSURLConnection*) connection 
     didReceiveData: (NSData*) data;
@end

//============================================================================
@interface DownloadOperation : AFHTTPRequestOperation
@property (assign, nonatomic) int retryCount;
@end

//============================================================================
@implementation DownloadOperation 
@synthesize retryCount = _retryCount;

//----------------------------------------------------------------------------
- (void) connection: (NSURLConnection*) connection 
 didReceiveResponse: (NSURLResponse*) response 
{
    [super connection: connection
   didReceiveResponse: response];

    _retryCount = 0;
    DFNLOG(@"GOT HTTP RESPONSE: %d", [(id)response statusCode]);
    DFNLOG(@"INITIAL REQUEST WAS: %@ (%@)", [connection originalRequest], [[connection originalRequest] allHTTPHeaderFields]);
    DFNLOG(@"CURRENT REQUEST IS: %@ (%@)", [connection currentRequest], [[connection currentRequest] allHTTPHeaderFields]);

    if (! [self hasAcceptableStatusCode])
    {
        [self cancel];
        if (self.completionBlock) self.completionBlock();
    }
}

//----------------------------------------------------------------------------
- (void) connection: (NSURLConnection*) connection 
     didReceiveData: (NSData*) data
{
    if (! [self isCancelled])
    {
        [super connection: connection 
           didReceiveData: data];
    }
}

@end



//============================================================================
@interface DownloadManager ()

@property (strong, nonatomic) NSOperationQueue* queue;
@end

//============================================================================
@implementation DownloadManager 

@synthesize queue = _queue;

//----------------------------------------------------------------------------
- (NSString*) md5ForFileAtPath: (NSString*) path
{
    CC_MD5_CTX ctx;
    NSMutableString* md5str = nil;
    
    CC_MD5_Init (&ctx);

    const size_t BUF_SIZE = 0x10000;
    char buf [BUF_SIZE];
    FILE* file = fopen ([path fileSystemRepresentation], "r");
    if (file)
    {
        size_t nbytes;
        while (0 < (nbytes = fread (buf, 1, BUF_SIZE, file)))
        {
            CC_MD5_Update (&ctx, buf, nbytes);
        }
        fclose (file);
        
        unsigned char md5 [CC_MD5_DIGEST_LENGTH];
        CC_MD5_Final (md5, &ctx);
        
        md5str = [NSMutableString stringWithCapacity: (2 * CC_MD5_DIGEST_LENGTH)];
        for (int i = 0; i < CC_MD5_DIGEST_LENGTH; ++i)
        {
            [md5str appendFormat: @"%02x", md5[i]];
        }
    }
    
QUIT:
    if (file) fclose (file);
    return md5str;
}

//----------------------------------------------------------------------------
- (void) cancelOperationForURL: (NSURL*) url
{
    NSUInteger i = [_queue.operations indexOfObjectPassingTest: 
                   ^(DownloadOperation* obj, NSUInteger idx, BOOL *stop) 
                   { return (BOOL)(([url isEqual: obj.request.URL]) ? (*stop = YES) : NO); }];

    if (i != NSNotFound)
    {
        [[_queue.operations objectAtIndex: i] cancel];
    }
}

//----------------------------------------------------------------------------
- init
{
    if (! (self = [super init])) return nil;

    _queue = [NSOperationQueue new];

    [_queue setName: DMGR_QUEUE_NAME];
    [_queue setMaxConcurrentOperationCount: 1];

    return self;
}

//----------------------------------------------------------------------------
- (BOOL) downloadFileAtURL: (NSURL*) url
                    toPath: (NSString*) filepath
         completionHandler: (void (^)(NSError* err)) completionHandler
             updateHandler: (void (^)(size_t downloaded, size_t expected)) updateHandler
                retryCount: (int) recount
{
    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL: url];
    NSFileManager* fm = [NSFileManager defaultManager];


    //unlink ([filepath fileSystemRepresentation]);

    NSString* datapath = STR_ADDEXT (filepath, @"partial");

    size_t flen = 0;
    if ([fm fileExistsAtPath: datapath])
    {
        NSError* err;
        NSDictionary* attrs = [fm attributesOfItemAtPath: datapath
                                                   error: &err];
        if (attrs) 
        {
            flen = attrs.fileSize;
            if (flen) {
                id val = STRF(@"bytes=%d-", flen);
                [req setValue: val forHTTPHeaderField: @"Range"];
            }
        }
    }


    DownloadOperation* op = [[DownloadOperation alloc] initWithRequest: req];
    op.outputStream = [NSOutputStream outputStreamToFileAtPath: datapath append: YES];

    BOOL (^retryBlock)(int) = 
        ^(int retryCount) 
        {
            static double _s_retry_delays[] = { 2, 3, 5 };     
             
            if (retryCount < NELEMS (_s_retry_delays)) 
            {
                dispatch_after (dispatch_time (DISPATCH_TIME_NOW, _s_retry_delays [retryCount] * NSEC_PER_SEC),
                                dispatch_get_main_queue(),
                                ^{
                                    [self downloadFileAtURL: url
                                                     toPath: filepath
                                          completionHandler: completionHandler
                                              updateHandler: updateHandler
                                                 retryCount: (retryCount + 1)];
                                });
                return YES;
            }
            return NO;
        };  
    

    id successBlock = 
        ^(DownloadOperation* operation, id responseObject) 
        {
             DFNLOG(@"IN SUCCESS COMPLETION HANDLER FOR REQUEST: %@", req);
             DFNLOG(@"MD5 for \"%@\": %@", datapath, [self md5ForFileAtPath: datapath]);
             
             unlink ([filepath fileSystemRepresentation]);

             NSError* err = nil;
             [[NSFileManager defaultManager] 
                 moveItemAtPath: datapath
                         toPath: filepath
                          error: &err];
             
             if (completionHandler) completionHandler (err);
        };

    id failureBlock = 
        ^(DownloadOperation* operation, NSError *error) 
        {
            DFNLOG(@"IN FAILURE COMPLETION HANDLER FOR REQUEST: %@", operation.request);
            DFNLOG(@"-- ERROR: %@", [error localizedDescription]);

            if (! ([operation isCancelled] || retryBlock (operation.retryCount)))
            {
                if (completionHandler) completionHandler (error);
            }
        };
         
    [op setShouldExecuteAsBackgroundTaskWithExpirationHandler: ^{ retryBlock(0); }];

    op.retryCount = recount;
    [op setDownloadProgressBlock:
        ^(NSInteger bytesRead, long long totalBytesRead, long long totalBytesExpectedToRead)
        {
            DFNLOG(@"GOT DATA OF LENGTH: %d", bytesRead);
            if (updateHandler) updateHandler (flen+totalBytesRead, flen+totalBytesExpectedToRead);
        }];

    [op setCompletionBlockWithSuccess: successBlock
                              failure: failureBlock];

    [self.queue addOperation: op];
    return YES;
}

//----------------------------------------------------------------------------
- (BOOL) downloadFileAtURL: (NSURL*) url
                    toPath: (NSString*) filepath
         completionHandler: (void (^)(NSError* err)) completionHandler
             updateHandler: (void (^)(size_t downloaded, size_t expected)) updateHandler
{
    return [self downloadFileAtURL: url
                            toPath: filepath
                 completionHandler: completionHandler
                     updateHandler: updateHandler
                        retryCount: 0];
}
@end

/* EOF */
