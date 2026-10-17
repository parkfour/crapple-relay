#import <Foundation/Foundation.h>
#import <IMCore/IMCore.h>

@interface IMService : NSObject

// Class Methods
+ (BOOL)isEmailAddress:(id)arg1 inDomains:(id)arg2;
+ (NSUInteger)myStatus;
+ (NSUInteger)statusForABPerson:(id)arg1;
+ (NSUInteger)statusForIMPerson:(id)arg1;
+ (id)aimService;
+ (id)allServices;
+ (id)allServicesNonBlocking;
+ (id)callService;
+ (id)canonicalFormOfID:(id)arg1 withIDSensitivity:(int)arg2;
+ (id)facetimeService;
+ (id)iMessageService;
+ (id)imageNameForStatus:(NSUInteger)arg1;
+ (id)imageURLForStatus:(NSUInteger)arg1;
+ (id)jabberService;
+ (id)myIdleTime;
+ (id)notificationCenter;
+ (id)serviceWithName:(id)arg1;
+ (id)smsService;
+ (id)subnetService;
+ (void)forgetStatusImageAppearance;

// Instance Methods
- (BOOL)initialSyncPerformed;
- (BOOL)isEnabled;
- (NSUInteger)status;
- (id)copyWithZone:(void *)arg1;
- (id)infoForAllPeople;
- (id)infoForAllScreenNames;
- (id)infoForDisplayedPeople;
- (id)infoForPerson:(id)arg1;
- (id)infoForPreferredScreenNames;
- (id)infoForScreenName:(id)arg1;
- (id)localizedName;
- (id)localizedShortName;
- (id)myScreenNames;
- (id)name;
- (id)peopleWithScreenName:(id)arg1;
- (id)screenNamesForPerson:(id)arg1;
- (void)login;
- (void)logout;

@end