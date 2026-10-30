#import <Foundation/Foundation.h>
// Deployment records are manual evidence, never a device hash attestation.
NSDictionary *TIONavigationCompatibility(NSDictionary *build, NSDictionary *deployment,
    NSString *device, NSTimeInterval now, NSString *supportedControlContract);
NSDictionary *TIONavigationCompatibilityStatus(void);
