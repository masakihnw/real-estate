#import "ObjCExceptionCatcher.h"

static NSString *const kErrorDomain = @"ObjCExceptionCatcher";

@implementation ObjCExceptionCatcher

+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block
               error:(NSError *_Nullable *_Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
            if (exception.reason) {
                userInfo[NSLocalizedDescriptionKey] = exception.reason;
            }
            if (exception.userInfo) {
                userInfo[@"ExceptionUserInfo"] = exception.userInfo;
            }
            userInfo[@"ExceptionName"] = exception.name;
            *error = [NSError errorWithDomain:kErrorDomain
                                         code:1
                                     userInfo:userInfo];
        }
        return NO;
    }
}

@end
