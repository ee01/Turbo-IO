#import <Foundation/Foundation.h>
// Distinct exported symbols are audited by the packager before any signing.
#if TIO_DAILY_NAVIGATION
NSString *TIODailyNavigationBuild(void){return @"TLC1-DAILY-01";}
#elif TIO_TLC1_UPGRADE
NSString *TIOTLC1UpgradeBuild(void){return @"TLC1-TOOL-01";}
#endif
