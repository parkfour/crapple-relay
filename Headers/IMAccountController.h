#import <Foundation/Foundation.h>
#import <IMCore/IMCore.h>

@interface IMAccountController : NSObject
{
    BOOL _isReadOnly;
    BOOL _cachesEnabled;
    NSArray * _operationalAccountsCache;
    NSMutableDictionary * _serviceToActiveAccountsMap;
    NSMutableDictionary * _serviceToAccountsMap;
    NSMutableDictionary * _serviceToConnectedAccountsMap;
    NSMutableDictionary * _serviceToOperationalAccountsMap;
    NSMutableDictionary * _accountMap;
    BOOL _networkDataAvailable;
    NSArray * _accounts;
}

// Properties
@property (copy, readwrite) NSArray *accounts;
@property (nonatomic, readwrite) BOOLnetworkDataAvailable;
@property (readonly, nonatomic) IMAccount *activeIMessageAccount;
@property (readonly, nonatomic) IMAccount *activeSMSAccount;
@property (readonly, nonatomic) NSArray *activeAccounts;
@property (readonly, nonatomic) NSArray *connectedAccounts;
@property (readonly, nonatomic) NSArray *operationalAccounts;
@property (readonly, nonatomic) idbestAccountForStatus;
@property (readonly, nonatomic) intnumberOfAccounts;

// Class Methods
+ (id)bestAccountFromAccounts:(id)arg1;
+ (id)sharedInstance;

// Instance Methods
- (BOOL)_deactivateAccount:(id)arg1;
- (BOOL)_deactivateAccounts:(id)arg1;
- (BOOL)_shouldPerformDeferredSetup;
- (BOOL)accountActive:(id)arg1;
- (BOOL)accountConnected:(id)arg1;
- (BOOL)accountConnecting:(id)arg1;
- (BOOL)activateAccount:(id)arg1 force:(BOOL)arg2 locally:(BOOL)arg3;
- (BOOL)activateAccount:(id)arg1 force:(BOOL)arg2;
- (BOOL)activateAccount:(id)arg1 locally:(BOOL)arg2;
- (BOOL)activateAccount:(id)arg1;
- (BOOL)activateAccounts:(id)arg1 force:(BOOL)arg2 locally:(BOOL)arg3;
- (BOOL)activateAccounts:(id)arg1;
- (BOOL)activateAndHandleReconnectAccount:(id)arg1;
- (BOOL)activateAndHandleReconnectAccounts:(id)arg1;
- (BOOL)addAccount:(id)arg1 atIndex:(int)arg2 locally:(BOOL)arg3;
- (BOOL)addAccount:(id)arg1 atIndex:(int)arg2;
- (BOOL)addAccount:(id)arg1 locally:(BOOL)arg2;
- (BOOL)addAccount:(id)arg1;
- (BOOL)canActivateAccount:(id)arg1;
- (BOOL)canActivateAccounts:(id)arg1;
- (BOOL)canDeleteAccount:(id)arg1;
- (BOOL)deactivateAccount:(id)arg1 withDisable:(BOOL)arg2;
- (BOOL)deactivateAccount:(id)arg1;
- (BOOL)deactivateAccounts:(id)arg1 withDisable:(BOOL)arg2;
- (BOOL)deactivateAccounts:(id)arg1;
- (BOOL)deleteAccount:(id)arg1 locally:(BOOL)arg2;
- (BOOL)deleteAccount:(id)arg1;
- (BOOL)metionedHandleMatchesMeCard:(id)arg1;
- (BOOL)networkDataAvailable;
- (BOOL)readOnly;
- (BOOL)receiverIsMyMention:(id)arg1;
- (NSInteger)activeAccountsAreEligibleForAppleSMSFilter;
- (NSInteger)activeAccountsAreEligibleForHawking;
- (NSInteger)activeAccountsAreEligibleForUnknownSendersFiltering;
- (id)__iCloudSystemAccountForService:(id)arg1;
- (id)_bestAccountForAddresses:(id)arg1;
- (id)_bestOperationalAccountForSendingForService:(id)arg1;
- (id)accountAtIndex:(int)arg1;
- (id)accountForUniqueID:(id)arg1;
- (id)accounts;
- (id)accountsForService:(id)arg1;
- (id)accountsWithCapability:(NSUInteger)arg1;
- (id)activeAccounts;
- (id)activeAccountsForService:(id)arg1;
- (id)activeAccountsSupportingStatus;
- (id)activeIMessageAccount;
- (id)activeSMSAccount;
- (id)aimAccount;
- (id)bestAccountForService:(id)arg1 login:(id)arg2 guid:(id)arg3;
- (id)bestAccountForService:(id)arg1 withLogin:(id)arg2;
- (id)bestAccountForService:(id)arg1;
- (id)bestAccountForStatus;
- (id)bestAccountWithCapability:(NSUInteger)arg1;
- (id)bestActiveAccountForService:(id)arg1 withLogin:(id)arg2;
- (id)bestActiveAccountForService:(id)arg1;
- (id)bestConnectedAccountForService:(id)arg1 withLogin:(id)arg2;
- (id)bestConnectedAccountForService:(id)arg1;
- (id)bestOperationalAccountForService:(id)arg1 withLogin:(id)arg2;
- (id)bestOperationalAccountForService:(id)arg1;
- (id)connectedAccounts;
- (id)connectedAccountsForService:(id)arg1;
- (id)connectedAccountsWithCapability:(NSUInteger)arg1;
- (id)iMessageAccountForLastAddressedHandle:(id)arg1 simID:(id)arg2;
- (id)init;
- (id)jabberAccount;
- (id)mostLoggedInAccount;
- (id)operationalAccounts;
- (id)operationalAccountsForService:(id)arg1;
- (id)operationalAccountsWithCapability:(NSUInteger)arg1;
- (int)numberOfAccounts;
- (void).cxx_destruct;
- (void)_accountRegistrationStatusChanged:(id)arg1;
- (void)_activeAccountChanged:(id)arg1;
- (void)_disableCache;
- (void)_enableCache;
- (void)_rebuildOperationalAccountsCache:(BOOL)arg1;
- (void)_requestNetworkDataAvailability;
- (void)accountLoginComplete:(id)arg1;
- (void)autoLogin;
- (void)dealloc;
- (void)deferredSetup;
- (void)setAccounts:(id)arg1;
- (void)setNetworkDataAvailable:(BOOL)arg1;
- (void)setReadOnly:(BOOL)arg1;

@end