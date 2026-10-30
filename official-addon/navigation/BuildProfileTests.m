#import "../ResearchCatalog.h"
#include <assert.h>
int main(void){@autoreleasepool{
 NSMutableSet *keys=[NSMutableSet new];
 for(NSString *p in @[@"model",@"library",@"diagnostics"])for(NSDictionary *s in TIOResearchSections(p))for(NSDictionary *r in s[@"rows"])[keys addObject:r[@"key"]];
 assert([keys containsObject:@"memoryUpload"]&&[keys containsObject:@"capture"]);
#if TIO_TLC1_UPGRADE
 assert(![keys containsObject:@"navigation"]&&[keys containsObject:@"experimentalOTA"]);
#else
 assert([keys containsObject:@"navigation"]&&![keys containsObject:@"experimentalOTA"]);
#endif
 puts("PASS profile routes preserve archive, separate daily navigation from TLC1 tool");
}return 0;}
