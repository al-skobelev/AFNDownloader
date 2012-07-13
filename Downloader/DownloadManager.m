/****************************************************************************
 * DownloadManager.m                                                        *
 * Created by Alexander Skobelev                                            *
 *                                                                          *
 ****************************************************************************/

#import "DownloadManager.h"
#import <AFNetworking.h>
#import <CommonCrypto/CommonDigest.h>
#import "CommonUtils.h"
#import "Reachability.h"

#define DMGR_QUEUE_NAME @"com.iziteq.downloadmanager.queue"

#define DFNLOG(FMT$, ARGS$...) fprintf (stderr, "%s\n", [STRF(FMT$, ##ARGS$) UTF8String])
// #define DFNLOG(FMT$, ARGS$...) NSLog (@"%s -- " FMT$, __PRETTY_FUNCTION__, ##ARGS$)

//============================================================================
@interface AFHTTPRequestOperation (SuperPrivateMethods)

- (void) connection: (NSURLConnection*) connection 
 didReceiveResponse: (NSURLResponse*) response;

- (void) connection: (NSURLConnection*) connection 
     didReceiveData: (NSData*) data;

- (void) connectionDidFinishLoading: (NSURLConnection*) connection;

- (void) connection: (NSURLConnection*) connection 
   didFailWithError: (NSError*) error;

@end

//============================================================================
@interface DownloadOperation : AFHTTPRequestOperation

@property (assign, nonatomic) int            retryCount;
@property (assign, nonatomic) NetworkStatus  networkStatus;
@property (copy, nonatomic)   id             completionUserHandler;
@property (copy, nonatomic)   id             updateUserHandler;
@property (strong, nonatomic) NSURL*         url;
@property (strong, nonatomic) NSString*      filepath;
@property (strong, nonatomic) NSMutableData* buffer;

@property (readwrite, nonatomic, retain) NSURLConnection *connection;
@end

#define BUFFER_LIMIT 200000

//============================================================================
@implementation DownloadOperation 

@synthesize retryCount            = _retryCount;
@synthesize networkStatus         = _networkStatus;
@synthesize completionUserHandler = _completionUserHandler;
@synthesize updateUserHandler     = _updateUserHandler;
@synthesize url                   = _url;
@synthesize filepath              = _filepath;
@synthesize buffer                = _buffer;

@dynamic connection;

//----------------------------------------------------------------------------
- (void) flushStreamBuffer: (BOOL) force
{
    if (self.connection && (self.buffer.length > (force ? 0 : BUFFER_LIMIT)))
    {
        [super connection: self.connection 
           didReceiveData: self.buffer];

        [self.buffer setLength: 0];
    }
}

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
        self.buffer = nil;
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
        [self.buffer appendData: data];
        [self flushStreamBuffer: NO];
    }
}

//----------------------------------------------------------------------------
- (void) connectionDidFinishLoading: (NSURLConnection*) connection 
{
    [self flushStreamBuffer: YES];

    [super connectionDidFinishLoading: connection];
}

//----------------------------------------------------------------------------
- (void) connection: (NSURLConnection*) connection 
   didFailWithError: (NSError*) error 
{
    [self flushStreamBuffer: YES];

    [super connection: connection 
     didFailWithError: error];
}

//----------------------------------------------------------------------------
- (void) start
{
    self.buffer = [NSMutableData dataWithCapacity: (BUFFER_LIMIT | 0xFFFF) + 1];
    [super start];

    self.networkStatus = [[Reachability reachabilityForLocalWiFi]
                             currentReachabilityStatus];
}

//----------------------------------------------------------------------------
- (void) cancel
{
    [self flushStreamBuffer: YES];
    self.buffer = nil;
    [super cancel];
}

@end



//============================================================================
@interface DownloadManager ()

@property (strong, nonatomic) NSOperationQueue* queue;
@property (strong, nonatomic) Reachability*     reachability;
@end

//============================================================================
@implementation DownloadManager 

@synthesize queue = _queue;
@synthesize reachability = _reachability;

//----------------------------------------------------------------------------
+ (NSString*) md5ForFileAtPath: (NSString*) path
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

    self.reachability = [Reachability reachabilityForLocalWiFi];
    [self.reachability startNotifier];

    ADD_OBSERVER (kReachabilityChangedNotification, self, onReachabilityChangedNtf:);
    return self;
}

//----------------------------------------------------------------------------
- (void) onReachabilityChangedNtf: (NSNotification*) ntf
{
    NetworkStatus status = [[ntf object] currentReachabilityStatus];
    if (ReachableViaWiFi == status)
    {
        [_queue.operations enumerateObjectsUsingBlock:
             ^(DownloadOperation* op, NSUInteger idx, BOOL *stop)
             {
                 if (op.isExecuting && op.networkStatus != ReachableViaWiFi)
                 {
                     [op cancel];
                     [self retryOperation: op];
                 }
             }];
    }
}

//----------------------------------------------------------------------------
- (BOOL) retryOperation: (DownloadOperation*) op
{
    return [self downloadFileAtURL: op.url
                            toPath: op.filepath
                 completionHandler: op.completionUserHandler
                     updateHandler: op.updateUserHandler
                        retryCount: op.retryCount];
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

    BOOL (^retryBlock)(DownloadOperation*) = 
        ^(DownloadOperation* op) 
        {
            static double _s_retry_delays[] = { 2, 3, 5 };     
             
            if (op.retryCount < NELEMS (_s_retry_delays)) 
            {
                dispatch_after (dispatch_time (DISPATCH_TIME_NOW, _s_retry_delays [op.retryCount] * NSEC_PER_SEC),
                                dispatch_get_main_queue(),
                                ^{
                                    ++op.retryCount;
                                    [self retryOperation: op];
                                });
                return YES;
            }
            return NO;
        };  
    

    id successBlock = 
        ^(DownloadOperation* op, id responseObject) 
        {
             DFNLOG (@"IN SUCCESS COMPLETION HANDLER FOR REQUEST: %@", req);
             DFNLOG (@"MD5 for \"%@\": %@", datapath, [DownloadManager md5ForFileAtPath: datapath]);
             
             unlink ([filepath fileSystemRepresentation]);

             NSError* err = nil;
             [[NSFileManager defaultManager] 
                 moveItemAtPath: datapath
                         toPath: filepath
                          error: &err];
             
             if (completionHandler) completionHandler (err);
        };

    id failureBlock = 
        ^(DownloadOperation* op, NSError *error) 
        {
            DFNLOG (@"IN FAILURE COMPLETION HANDLER FOR REQUEST: %@", op.request);
            DFNLOG (@"-- ERROR: %@", [error localizedDescription]);

            if (! ([op isCancelled] || retryBlock (op)))
            {
                if (completionHandler) completionHandler (error);
            }
        };
         

    id progressBlock = 
        ^(NSInteger bytesRead, long long totalBytesRead, long long totalBytesExpectedToRead)
        {
            DFNLOG(@"GOT DATA OF LENGTH: %d", bytesRead);
            if (updateHandler) updateHandler (flen + totalBytesRead, flen + totalBytesExpectedToRead);
        };



    DownloadOperation* op = [[DownloadOperation alloc] initWithRequest: req];
    op.outputStream = [NSOutputStream outputStreamToFileAtPath: datapath append: YES];

    op.completionUserHandler = completionHandler;
    op.updateUserHandler = updateHandler;
    op.filepath = filepath;
    op.url = url;
    op.retryCount = recount;

    DownloadOperation* __weak op_weak = op;
    [op setShouldExecuteAsBackgroundTaskWithExpirationHandler: ^{ 
         if (op_weak) { op_weak.retryCount = 0; retryBlock(op_weak); }}];
    
    [op setDownloadProgressBlock: progressBlock];
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
