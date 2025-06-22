#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <sys/utsname.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <string.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <signal.h>
#import <execinfo.h>
#import <sys/stat.h>

// MARK: - Global Variables & Forward Declarations

static UIWindow *settingsWindow = nil;
static BOOL hasShownSettings = NO;

void ShowSettingsUI(void);
void SetupGestureRecognizer(void);

// MARK: - Logging & Anti-Crash

void SafeLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[FakeTweak] %@", msg);
}

void CrashHandler(int sig) {
    SafeLog(@"=== SIGNAL CRASH DETECTED: %d ===", sig);
    void *callstack[128];
    int frames = backtrace(callstack, 128);
    char **symbols = backtrace_symbols(callstack, frames);
    for (int i = 0; i < frames; i++) {
        SafeLog(@"Frame %d: %s", i, symbols[i]);
    }
    free(symbols);
    signal(sig, SIG_DFL);
    raise(sig);
}

// MARK: - Settings Storage

@interface FakeSettings : NSObject
+ (instancetype)shared;
- (void)loadSettings;
- (void)saveSettings;
- (void)resetSettings;
@property (nonatomic, strong) NSMutableDictionary *settings;
@property (nonatomic, strong) NSMutableDictionary *toggles;
@property (nonatomic, strong) NSDictionary *originalValues;
@end

@implementation FakeSettings
+ (instancetype)shared {
    static FakeSettings *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FakeSettings alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        [self loadOriginalValues];
        [self loadSettings];
    }
    return self;
}

- (void)loadOriginalValues {
    UIDevice *device = [UIDevice currentDevice];
    NSBundle *bundle = [NSBundle mainBundle];
    struct utsname systemInfo;
    uname(&systemInfo);

    char osrelease[256];
    size_t size = sizeof(osrelease);
    if (sysctlbyname("kern.osrelease", osrelease, &size, NULL, 0) != 0) {
        osrelease[0] = '\0';
    }

    self.originalValues = @{
        @"systemVersion": device.systemVersion ?: @"Unknown",
        @"deviceModel": [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding] ?: @"Unknown",
        @"deviceName": device.name ?: @"Unknown",
        @"identifierForVendor": device.identifierForVendor.UUIDString ?: @"Unknown",
        @"bundleIdentifier": bundle.bundleIdentifier ?: @"Unknown",
        @"appVersion": [bundle.infoDictionary objectForKey:@"CFBundleShortVersionString"] ?: @"Unknown",
        @"bundleVersion": [bundle.infoDictionary objectForKey:@"CFBundleVersion"] ?: @"Unknown",
        @"displayName": [bundle.infoDictionary objectForKey:@"CFBundleDisplayName"] ?: @"Unknown",
        @"darwinVersion": [NSString stringWithCString:osrelease encoding:NSUTF8StringEncoding] ?: @"Unknown",
        @"wifiIP": @"192.168.1.100"
    };
}

- (void)loadSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    self.settings = [[defaults objectForKey:@"FakeSettings"] mutableCopy] ?: [NSMutableDictionary dictionary];
    self.toggles = [[defaults objectForKey:@"FakeToggles"] mutableCopy] ?: [NSMutableDictionary dictionary];

    NSDictionary *defaultFakeValues = @{}; // Empty dictionary to prevent automatic default values

    [defaultFakeValues enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if (!self.settings[key]) self.settings[key] = @""; // Initialize with empty string
        if (!self.toggles[key]) self.toggles[key] = @NO;
    }];
    if (!self.toggles[@"jailbreak"]) self.toggles[@"jailbreak"] = @NO;
}

- (void)saveSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:self.settings forKey:@"FakeSettings"];
    [defaults setObject:self.toggles forKey:@"FakeToggles"];
    [defaults synchronize];
}

- (void)resetSettings {
    self.settings = [NSMutableDictionary dictionary];
    self.toggles = [NSMutableDictionary dictionary];
    [self saveSettings];
}

- (BOOL)isEnabled:(NSString *)key {
    return [self.toggles[key] boolValue];
}

- (NSString *)valueForKey:(NSString *)key {
    return self.settings[key] ?: self.originalValues[key] ?: @"N/A";
}
@end

// MARK: - Settings UI

@interface FakeSettingsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *settingsKeys;
@property (nonatomic, strong) NSDictionary *settingsLabels;
@end

@implementation FakeSettingsViewController

// MARK: - UI Constants
static const CGFloat kHeaderHeight = 140.0;
static const CGFloat kHeaderPaddingTop = 10.0;
static const CGFloat kHeaderSpacing = 25.0;
static const CGFloat kButtonContainerHeight = 70.0;
static const CGFloat kButtonFooterGap = 10.0;
static const CGFloat kFooterViewHeight = 50.0;
static const CGFloat kFooterPaddingBottom = 10.0;

- (void)viewDidLoad {
    [super viewDidLoad];
    self.settingsKeys = @[@"systemVersion", @"deviceModel", @"deviceName", @"identifierForVendor",
                         @"bundleIdentifier", @"appVersion", @"bundleVersion", @"displayName",
                         @"darwinVersion", @"wifiIP", @"jailbreak"];
    self.settingsLabels = @{
        @"systemVersion": @"🔢 System Version",
        @"deviceModel": @"📱 Device Model",
        @"deviceName": @"📝 Device Name",
        @"identifierForVendor": @"🆔 Vendor ID",
        @"bundleIdentifier": @"📦 Bundle ID",
        @"appVersion": @"📋 App Version",
        @"bundleVersion": @"🔖 Bundle Version",
        @"displayName": @"🏷️ Display Name",
        @"darwinVersion": @"🖥️ Darwin Version",
        @"wifiIP": @"🌐 WiFi IP",
        @"jailbreak": @"🔓 Anti-Jailbreak Detection"
    };
    [self setupUI];
}

- (void)setupUI {
    UIEdgeInsets safeInsets = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        safeInsets = self.view.safeAreaInsets;
        if (UIEdgeInsetsEqualToEdgeInsets(safeInsets, UIEdgeInsetsZero)) {
             safeInsets = UIEdgeInsetsMake(44.0, 0.0, 34.0, 0.0);
        }
    } else {
        safeInsets = UIEdgeInsetsMake(64.0, 0.0, 0.0, 0.0);
    }

    BOOL isDarkMode = NO;
    if (@available(iOS 13.0, *)) {
        isDarkMode = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    }

    // MARK: Background Gradients
    CAGradientLayer *gradient1 = [CAGradientLayer layer];
    gradient1.frame = self.view.bounds;
    CAGradientLayer *gradient2 = [CAGradientLayer layer];
    gradient2.frame = self.view.bounds;

    if (isDarkMode) {
        gradient1.colors = @[
            (id)[UIColor colorWithRed:0.05 green:0.05 blue:0.15 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.15 green:0.05 blue:0.25 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.05 green:0.15 blue:0.35 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.25 green:0.05 blue:0.20 alpha:1.0].CGColor
        ];
        gradient2.colors = @[
            (id)[UIColor colorWithRed:0.10 green:0.05 blue:0.20 alpha:0.8].CGColor,
            (id)[UIColor colorWithRed:0.05 green:0.20 blue:0.30 alpha:0.8].CGColor,
            (id)[UIColor colorWithRed:0.20 green:0.10 blue:0.35 alpha:0.8].CGColor,
            (id)[UIColor colorWithRed:0.15 green:0.25 blue:0.10 alpha:0.8].CGColor
        ];
    } else {
        gradient1.colors = @[
            (id)[UIColor colorWithRed:0.2 green:0.4 blue:0.95 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.7 green:0.2 blue:0.9 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.95 green:0.3 blue:0.5 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.3 green:0.8 blue:0.6 alpha:1.0].CGColor
        ];
        gradient2.colors = @[
            (id)[UIColor colorWithRed:0.4 green:0.6 blue:0.98 alpha:0.7].CGColor,
            (id)[UIColor colorWithRed:0.9 green:0.4 blue:0.8 alpha:0.7].CGColor,
            (id)[UIColor colorWithRed:0.8 green:0.5 blue:0.9 alpha:0.7].CGColor,
            (id)[UIColor colorWithRed:0.5 green:0.9 blue:0.7 alpha:0.7].CGColor
        ];
    }

    gradient1.startPoint = CGPointMake(0, 0);
    gradient1.endPoint = CGPointMake(1, 1);
    gradient2.startPoint = CGPointMake(1, 0);
    gradient2.endPoint = CGPointMake(0, 1);

    [self.view.layer insertSublayer:gradient1 atIndex:0];
    [self.view.layer insertSublayer:gradient2 atIndex:1];

    CABasicAnimation *animation1 = [CABasicAnimation animationWithKeyPath:@"colors"];
    animation1.duration = 8.0; animation1.repeatCount = INFINITY; animation1.autoreverses = YES;
    [gradient1 addAnimation:animation1 forKey:@"colorAnimation"];

    CABasicAnimation *animation2 = [CABasicAnimation animationWithKeyPath:@"startPoint"];
    animation2.fromValue = [NSValue valueWithCGPoint:CGPointMake(0, 0)];
    animation2.toValue = [NSValue valueWithCGPoint:CGPointMake(1, 1)];
    animation2.duration = 6.0; animation2.repeatCount = INFINITY; animation2.autoreverses = YES;
    [gradient2 addAnimation:animation2 forKey:@"pointAnimation"];

    // MARK: Floating Particles Effect
    for (int i = 0; i < 15; i++) {
        UIView *particle = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 4, 4)];
        particle.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.3];
        particle.layer.cornerRadius = 2;
        particle.center = CGPointMake(arc4random_uniform((int)self.view.frame.size.width),
                                    arc4random_uniform((int)self.view.frame.size.height));
        [self.view addSubview:particle];

        [UIView animateWithDuration:3.0 + (arc4random_uniform(4000) / 1000.0)
                              delay:(arc4random_uniform(2000) / 1000.0)
                            options:UIViewAnimationOptionRepeat | UIViewAnimationOptionAutoreverse
                         animations:^{
                             particle.center = CGPointMake(arc4random_uniform((int)self.view.frame.size.width),
                                                           arc4random_uniform((int)self.view.frame.size.height));
                             particle.alpha = 0.1 + (arc4random_uniform(30) / 100.0);
                         } completion:nil];
    }

    // MARK: Close Button
    CGFloat closeButtonTop = safeInsets.top + kHeaderPaddingTop;
    UIView *closeContainer = [[UIView alloc] initWithFrame:CGRectMake(self.view.frame.size.width - 60, closeButtonTop, 50, 50)];
    closeContainer.backgroundColor = [UIColor clearColor];

    UIView *glowView = [[UIView alloc] initWithFrame:CGRectMake(5, 5, 40, 40)];
    glowView.backgroundColor = [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:0.8];
    glowView.layer.cornerRadius = 20;
    glowView.layer.shadowColor = [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:1.0].CGColor;
    glowView.layer.shadowOffset = CGSizeMake(0, 0);
    glowView.layer.shadowOpacity = 0.8;
    glowView.layer.shadowRadius = 10;
    [closeContainer addSubview:glowView];



    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    closeButton.frame = CGRectMake(5, 5, 40, 40);
    [closeButton setTitle:@"✕" forState:UIControlStateNormal];
    closeButton.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightHeavy];
    [closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    closeButton.backgroundColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:0.9];
    closeButton.layer.cornerRadius = 20;
    closeButton.layer.borderWidth = 2;
    closeButton.layer.borderColor = [UIColor whiteColor].CGColor;
    [closeButton addTarget:self action:@selector(closeSettings) forControlEvents:UIControlEventTouchUpInside];
    [closeContainer addSubview:closeButton];

    // MARK: Header
    CGFloat headerTop = safeInsets.top + kHeaderPaddingTop;
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(10, headerTop, self.view.frame.size.width - 20, kHeaderHeight)];
    headerView.backgroundColor = [UIColor clearColor];

    UIVisualEffectView *headerBlur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    headerBlur.frame = headerView.bounds;
    headerBlur.alpha = 0.6;
    headerBlur.layer.cornerRadius = 25;
    headerBlur.layer.masksToBounds = YES;
    headerBlur.layer.borderWidth = 1;
    headerBlur.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.2].CGColor;
    [headerView addSubview:headerBlur];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 25, headerView.frame.size.width - 40, 55)];
    titleLabel.text = @"🎭 FAKE INFO ULTRA";
    titleLabel.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBlack];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.layer.shadowColor = [UIColor blackColor].CGColor;
    titleLabel.layer.shadowOffset = CGSizeMake(0, 4);
    titleLabel.layer.shadowOpacity = 0.8;
    titleLabel.layer.shadowRadius = 8;
    [headerView addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 80, headerView.frame.size.width - 40, 30)];
    subtitleLabel.text = @"✨ Tweak: Fake Device Info ✨";
    subtitleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.95];
    subtitleLabel.textAlignment = NSTextAlignmentCenter;
    [headerView addSubview:subtitleLabel];

    UILabel *statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 110, headerView.frame.size.width - 40, 20)];
    statusLabel.text = @"🟢 System Ready • 🔥 Ultra Mode Active";
    statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    statusLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.8];
    statusLabel.textAlignment = NSTextAlignmentCenter;
    [headerView addSubview:statusLabel];

    [self.view addSubview:headerView];
    [self.view addSubview:closeContainer];

    // MARK: Table View
    CGFloat tableY = headerTop + kHeaderHeight + kHeaderSpacing;
    CGFloat totalBottomControlAreaHeight = kButtonContainerHeight + kButtonFooterGap + kFooterViewHeight + kFooterPaddingBottom;
    CGFloat bottomControlAreaTop = self.view.frame.size.height - totalBottomControlAreaHeight - safeInsets.bottom;
    CGFloat tableHeight = bottomControlAreaTop - tableY;
    if (tableHeight < 0) tableHeight = 0;

    UIView *tableContainer = [[UIView alloc] initWithFrame:CGRectMake(10, tableY, self.view.frame.size.width - 20, tableHeight)];
    tableContainer.backgroundColor = [UIColor clearColor];
    tableContainer.layer.cornerRadius = 25;

    UIVisualEffectView *tableBlur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    tableBlur.frame = tableContainer.bounds;
    tableBlur.alpha = 0.4;
    tableBlur.layer.cornerRadius = 25;
    tableBlur.layer.masksToBounds = YES;
    tableBlur.layer.borderWidth = 1;
    tableBlur.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
    [tableContainer addSubview:tableBlur];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.layer.cornerRadius = 20;
    self.tableView.layer.masksToBounds = YES;
    self.tableView.showsVerticalScrollIndicator = NO;
    self.tableView.contentInset = UIEdgeInsetsMake(15, 0, 15, 0);
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [tableContainer addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [NSLayoutConstraint constraintWithItem:self.tableView attribute:NSLayoutAttributeLeading relatedBy:NSLayoutRelationEqual toItem:tableContainer attribute:NSLayoutAttributeLeading multiplier:1.0 constant:5.0],
        [NSLayoutConstraint constraintWithItem:self.tableView attribute:NSLayoutAttributeTrailing relatedBy:NSLayoutRelationEqual toItem:tableContainer attribute:NSLayoutAttributeTrailing multiplier:1.0 constant:-5.0],
        [NSLayoutConstraint constraintWithItem:self.tableView attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:tableContainer attribute:NSLayoutAttributeTop multiplier:1.0 constant:5.0],
        [NSLayoutConstraint constraintWithItem:self.tableView attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:tableContainer attribute:NSLayoutAttributeBottom multiplier:1.0 constant:-5.0],
    ]];
    [self.view addSubview:tableContainer];

    // MARK: Action Buttons
    CGFloat buttonsAndFooterTopY = self.view.frame.size.height - (kButtonContainerHeight + kButtonFooterGap + kFooterViewHeight + kFooterPaddingBottom) - safeInsets.bottom;
    CGFloat buttonWidth = (self.view.frame.size.width - 50.0) / 2.0;

    UIView *saveContainer = [[UIView alloc] initWithFrame:CGRectMake(20, buttonsAndFooterTopY, buttonWidth, kButtonContainerHeight)];
    UIView *saveGlow = [[UIView alloc] initWithFrame:CGRectMake(5, 5, saveContainer.frame.size.width - 10, kButtonContainerHeight - 10)];
    saveGlow.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.3];
    saveGlow.layer.cornerRadius = kButtonContainerHeight / 2.0 - 5.0;
    saveGlow.layer.shadowColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1.0].CGColor;
    saveGlow.layer.shadowOffset = CGSizeMake(0, 0);
    saveGlow.layer.shadowOpacity = 0.8;
    saveGlow.layer.shadowRadius = 15;
    [saveContainer addSubview:saveGlow];

    UIButton *saveButton = [UIButton buttonWithType:UIButtonTypeCustom];
    saveButton.frame = CGRectMake(5, 5, saveContainer.frame.size.width - 10, kButtonContainerHeight - 10);
    [saveButton setTitle:@"💾 SAVE & EXIT" forState:UIControlStateNormal];
    saveButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightHeavy];
    [saveButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    CAGradientLayer *saveGradient = [CAGradientLayer layer];
    saveGradient.frame = saveButton.bounds;
    saveGradient.colors = @[
        (id)[UIColor colorWithRed:0.2 green:0.9 blue:0.4 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.1 green:0.7 blue:0.3 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.0 green:0.8 blue:0.2 alpha:1.0].CGColor
    ];
    saveGradient.cornerRadius = kButtonContainerHeight / 2.0 - 5.0;
    [saveButton.layer insertSublayer:saveGradient atIndex:0];

    saveButton.layer.cornerRadius = kButtonContainerHeight / 2.0 - 5.0;
    saveButton.layer.borderWidth = 2;
    saveButton.layer.borderColor = [UIColor whiteColor].CGColor;
    [saveButton addTarget:self action:@selector(saveAndExit) forControlEvents:UIControlEventTouchUpInside];
    [saveContainer addSubview:saveButton];
    [self.view addSubview:saveContainer];

    UIView *resetContainer = [[UIView alloc] initWithFrame:CGRectMake(30 + buttonWidth, buttonsAndFooterTopY, buttonWidth, kButtonContainerHeight)];
    UIView *resetGlow = [[UIView alloc] initWithFrame:CGRectMake(5, 5, resetContainer.frame.size.width - 10, kButtonContainerHeight - 10)];
    resetGlow.backgroundColor = [UIColor colorWithRed:0.9 green:0.3 blue:0.3 alpha:0.3];
    resetGlow.layer.cornerRadius = kButtonContainerHeight / 2.0 - 5.0;
    resetGlow.layer.shadowColor = [UIColor colorWithRed:0.9 green:0.3 blue:0.3 alpha:1.0].CGColor;
    resetGlow.layer.shadowOffset = CGSizeMake(0, 0);
    resetGlow.layer.shadowOpacity = 0.8;
    resetGlow.layer.shadowRadius = 15;
    [resetContainer addSubview:resetGlow];

    UIButton *resetButton = [UIButton buttonWithType:UIButtonTypeCustom];
    resetButton.frame = CGRectMake(5, 5, resetContainer.frame.size.width - 10, kButtonContainerHeight - 10);
    [resetButton setTitle:@"🔄 RESET ALL" forState:UIControlStateNormal];
    resetButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightHeavy];
    [resetButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    CAGradientLayer *resetGradient = [CAGradientLayer layer];
    resetGradient.frame = resetButton.bounds;
    resetGradient.colors = @[
        (id)[UIColor colorWithRed:1.0 green:0.4 blue:0.4 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.8 green:0.1 blue:0.1 alpha:1.0].CGColor
    ];
    resetGradient.cornerRadius = kButtonContainerHeight / 2.0 - 5.0;
    [resetButton.layer insertSublayer:resetGradient atIndex:0];

    resetButton.layer.cornerRadius = kButtonContainerHeight / 2.0 - 5.0;
    resetButton.layer.borderWidth = 2;
    resetButton.layer.borderColor = [UIColor whiteColor].CGColor;
    [resetButton addTarget:self action:@selector(resetSettings) forControlEvents:UIControlEventTouchUpInside];
    [resetContainer addSubview:resetButton];
    [self.view addSubview:resetContainer];

    CABasicAnimation *saveAnimation = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    saveAnimation.fromValue = @1.0; saveAnimation.toValue = @1.05;
    saveAnimation.duration = 2.0; saveAnimation.repeatCount = INFINITY; saveAnimation.autoreverses = YES;
    [saveGlow.layer addAnimation:saveAnimation forKey:@"saveGlow"];

    CABasicAnimation *resetAnimation = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    resetAnimation.fromValue = @1.0; resetAnimation.toValue = @1.05;
    resetAnimation.duration = 2.5; resetAnimation.repeatCount = INFINITY; resetAnimation.autoreverses = YES;
    [resetGlow.layer addAnimation:resetAnimation forKey:@"resetGlow"];

    // MARK: Footer
    CGFloat footerY = self.view.frame.size.height - kFooterViewHeight - safeInsets.bottom;
    UIView *footerView = [[UIView alloc] initWithFrame:CGRectMake(15, footerY, self.view.frame.size.width - 30, kFooterViewHeight)];
    footerView.backgroundColor = [UIColor clearColor];

    UIVisualEffectView *footerBlur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    footerBlur.frame = footerView.bounds;
    footerBlur.alpha = 0.5;
    footerBlur.layer.cornerRadius = 25;
    footerBlur.layer.masksToBounds = YES;
    [footerView addSubview:footerBlur];

    UILabel *authorLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, kFooterPaddingBottom, footerView.frame.size.width - 30, 20)];
    authorLabel.text = @"👨‍💻 Created by @dothanh1110 • Premium Edition";
    authorLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    authorLabel.textColor = [UIColor whiteColor];
    authorLabel.textAlignment = NSTextAlignmentCenter;
    [footerView addSubview:authorLabel];

    UILabel *contactLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, kFooterPaddingBottom + 20, footerView.frame.size.width - 30, 20)];
    contactLabel.text = @"📱 t.me/ctdotech • 🌐 ctdo.net • 🤏 Hold 4 fingers (0.3s) or Triple tap to reopen";
    contactLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    contactLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.8];
    contactLabel.textAlignment = NSTextAlignmentCenter;
    [footerView addSubview:contactLabel];

    [self.view addSubview:footerView];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.view.transform = CGAffineTransformMakeScale(0.8, 0.8);
    self.view.alpha = 0.0;
    [UIView animateWithDuration:0.6 delay:0.0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5 options:0 animations:^{
        self.view.transform = CGAffineTransformIdentity;
        self.view.alpha = 1.0;
    } completion:nil];
}

// MARK: - Helper Methods

- (UIButton *)createSocialButtonWithTitle:(NSString *)title backgroundColor:(UIColor *)backgroundColor action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.backgroundColor = backgroundColor;
    button.layer.cornerRadius = 17.5;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.3].CGColor;
    button.layer.shadowColor = backgroundColor.CGColor;
    button.layer.shadowOffset = CGSizeMake(0, 0);
    button.layer.shadowOpacity = 0.6;
    button.layer.shadowRadius = 8;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)addMovingStarsToContainer:(UIView *)container {
    for (int i = 0; i < 25; i++) {
        UIView *star = [self createStarView];
        [container addSubview:star];
        
        CGFloat startX = arc4random_uniform((int)container.frame.size.width);
        CGFloat startY = arc4random_uniform((int)container.frame.size.height);
        star.center = CGPointMake(startX, startY);
        
        [self animateStarMovement:star inContainer:container];
        
        [self animateStarTwinkle:star];
    }
    
    [self addShootingStarsToContainer:container];
}

- (UIView *)createStarView {
    CGFloat size = 1.5 + (arc4random_uniform(25) / 10.0);
    UIView *star = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    
    CAShapeLayer *starLayer = [CAShapeLayer layer];
    UIBezierPath *starPath = [self createStarPath:size];
    starLayer.path = starPath.CGPath;
    starLayer.fillColor = [UIColor whiteColor].CGColor;
    starLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.8].CGColor;
    starLayer.lineWidth = 0.5;
    
    starLayer.shadowColor = [UIColor colorWithRed:0.8 green:0.9 blue:1.0 alpha:1.0].CGColor;
    starLayer.shadowOffset = CGSizeMake(0, 0);
    starLayer.shadowOpacity = 0.8;
    starLayer.shadowRadius = size / 2;
    
    [star.layer addSublayer:starLayer];
    return star;
}

- (UIBezierPath *)createStarPath:(CGFloat)size {
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGFloat center = size / 2;
    CGFloat outerRadius = size / 2;
    CGFloat innerRadius = size / 4;
    
    for (int i = 0; i < 5; i++) {
        CGFloat angle = (i * 4 * M_PI) / 5 - M_PI_2;
        CGFloat x = center + outerRadius * cos(angle);
        CGFloat y = center + outerRadius * sin(angle);
        
        if (i == 0) {
            [path moveToPoint:CGPointMake(x, y)];
        } else {
            [path addLineToPoint:CGPointMake(x, y)];
        }
        
        angle += (2 * M_PI) / 5;
        x = center + innerRadius * cos(angle);
        y = center + innerRadius * sin(angle);
        [path addLineToPoint:CGPointMake(x, y)];
    }
    
    [path closePath];
    return path;
}

- (void)animateStarMovement:(UIView *)star inContainer:(UIView *)container {
    // Slow drifting movement
    CGFloat duration = 15.0 + (arc4random_uniform(100) / 10.0); // 15-25 seconds
    CGFloat endX = arc4random_uniform((int)container.frame.size.width);
    CGFloat endY = arc4random_uniform((int)container.frame.size.height);
    
    [UIView animateWithDuration:duration
                          delay:0
                        options:UIViewAnimationOptionRepeat | UIViewAnimationOptionAutoreverse | UIViewAnimationOptionCurveLinear
                     animations:^{
                         star.center = CGPointMake(endX, endY);
                     } completion:nil];
}

- (void)animateStarTwinkle:(UIView *)star {
    CGFloat duration = 2.0 + (arc4random_uniform(30) / 10.0);
    CGFloat delay = arc4random_uniform(20) / 10.0;
    
    [UIView animateWithDuration:duration
                          delay:delay
                        options:UIViewAnimationOptionRepeat | UIViewAnimationOptionAutoreverse
                     animations:^{
                         star.alpha = 0.3 + (arc4random_uniform(50) / 100.0);
                     } completion:nil];
}

- (void)addShootingStarsToContainer:(UIView *)container {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (8 + arc4random_uniform(7)) * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self createShootingStar:container];
        [self addShootingStarsToContainer:container];
    });
}

- (void)createShootingStar:(UIView *)container {
    UIView *shootingStar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 2, 2)];
    shootingStar.backgroundColor = [UIColor colorWithRed:0.9 green:0.95 blue:1.0 alpha:1.0];
    shootingStar.layer.cornerRadius = 1;
    
    // Add glow effect
    shootingStar.layer.shadowColor = [UIColor colorWithRed:0.8 green:0.9 blue:1.0 alpha:1.0].CGColor;
    shootingStar.layer.shadowOffset = CGSizeMake(0, 0);
    shootingStar.layer.shadowOpacity = 1.0;
    shootingStar.layer.shadowRadius = 3;
    
    // Start from random edge
    CGFloat startX = -10;
    CGFloat startY = arc4random_uniform((int)container.frame.size.height);
    CGFloat endX = container.frame.size.width + 10;
    CGFloat endY = arc4random_uniform((int)container.frame.size.height);
    
    shootingStar.center = CGPointMake(startX, startY);
    [container addSubview:shootingStar];
    
    // Animate shooting star
    [UIView animateWithDuration:1.5
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         shootingStar.center = CGPointMake(endX, endY);
                         shootingStar.alpha = 0.0;
                     } completion:^(BOOL finished) {
                         [shootingStar removeFromSuperview];
                     }];
    
    // Add trail effect
    [self addTrailToShootingStar:shootingStar inContainer:container startPoint:CGPointMake(startX, startY) endPoint:CGPointMake(endX, endY)];
}

- (void)addTrailToShootingStar:(UIView *)shootingStar inContainer:(UIView *)container startPoint:(CGPoint)start endPoint:(CGPoint)end {
    // Create trail effect
    CAShapeLayer *trailLayer = [CAShapeLayer layer];
    UIBezierPath *trailPath = [UIBezierPath bezierPath];
    [trailPath moveToPoint:start];
    [trailPath addLineToPoint:end];
    
    trailLayer.path = trailPath.CGPath;
    trailLayer.strokeColor = [UIColor colorWithRed:0.8 green:0.9 blue:1.0 alpha:0.6].CGColor;
    trailLayer.lineWidth = 1.0;
    trailLayer.lineCap = kCALineCapRound;
    
    trailLayer.shadowColor = [UIColor colorWithRed:0.8 green:0.9 blue:1.0 alpha:1.0].CGColor;
    trailLayer.shadowOffset = CGSizeMake(0, 0);
    trailLayer.shadowOpacity = 0.8;
    trailLayer.shadowRadius = 2;
    
    [container.layer insertSublayer:trailLayer atIndex:1];
    
    CABasicAnimation *trailAnimation = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
    trailAnimation.fromValue = @0.0;
    trailAnimation.toValue = @1.0;
    trailAnimation.duration = 1.5;
    
    CABasicAnimation *fadeAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fadeAnimation.fromValue = @0.8;
    fadeAnimation.toValue = @0.0;
    fadeAnimation.duration = 1.5;
    
    [trailLayer addAnimation:trailAnimation forKey:@"strokeEnd"];
    [trailLayer addAnimation:fadeAnimation forKey:@"opacity"];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [trailLayer removeFromSuperlayer];
    });
}

// MARK: - Social Media Actions

- (void)openGitHub {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
    }
    
    NSURL *url = [NSURL URLWithString:@"https://github.com/thanhdo1110"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        } else {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [[UIApplication sharedApplication] openURL:url];
            #pragma clang diagnostic pop
        }
    } else {
        [self showLinkCopiedAlert:@"GitHub" link:@"https://github.com/thanhdo1110"];
    }
}

- (void)openTelegram {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
    }
    
    NSURL *telegramURL = [NSURL URLWithString:@"tg://resolve?domain=ctdotech"];
    NSURL *webURL = [NSURL URLWithString:@"https://t.me/ctdotech"];
    
    if ([[UIApplication sharedApplication] canOpenURL:telegramURL]) {
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:telegramURL options:@{} completionHandler:nil];
        } else {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [[UIApplication sharedApplication] openURL:telegramURL];
            #pragma clang diagnostic pop
        }
    } else if ([[UIApplication sharedApplication] canOpenURL:webURL]) {
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:webURL options:@{} completionHandler:nil];
        } else {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [[UIApplication sharedApplication] openURL:webURL];
            #pragma clang diagnostic pop
        }
    } else {
        [self showLinkCopiedAlert:@"Telegram" link:@"t.me/ctdotech"];
    }
}

- (void)openWebsite {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
    }
    
    NSURL *url = [NSURL URLWithString:@"https://ctdo.net"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        } else {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [[UIApplication sharedApplication] openURL:url];
            #pragma clang diagnostic pop
        }
    } else {
        [self showLinkCopiedAlert:@"Website" link:@"https://ctdo.net"];
    }
}

- (void)showLinkCopiedAlert:(NSString *)platform link:(NSString *)link {
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    pasteboard.string = link;
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"📋 %@ Link Copied!", platform]
                                                                   message:[NSString stringWithFormat:@"Link has been copied to clipboard:\n%@", link]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *okFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [okFeedback impactOccurred];
        }
    }];
    
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

// MARK: - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return self.settingsKeys.count;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"FAKE SETTINGS";
    return @"AUTHOR INFO";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"AuthorCell"];
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        // Main container with gradient background
        UIView *mainContainer = [[UIView alloc] init];
        mainContainer.translatesAutoresizingMaskIntoConstraints = NO;
        mainContainer.layer.cornerRadius = 25;
        mainContainer.layer.masksToBounds = YES;
        [cell.contentView addSubview:mainContainer];

        // Space-themed gradient background
        CAGradientLayer *gradientLayer = [CAGradientLayer layer];
        gradientLayer.colors = @[
            (id)[UIColor colorWithRed:0.05 green:0.05 blue:0.2 alpha:0.95].CGColor,  // Deep space purple
            (id)[UIColor colorWithRed:0.1 green:0.05 blue:0.3 alpha:0.95].CGColor,   // Dark purple
            (id)[UIColor colorWithRed:0.15 green:0.1 blue:0.4 alpha:0.95].CGColor,   // Medium purple
            (id)[UIColor colorWithRed:0.05 green:0.15 blue:0.35 alpha:0.95].CGColor, // Deep blue
            (id)[UIColor colorWithRed:0.0 green:0.1 blue:0.25 alpha:0.95].CGColor    // Dark navy
        ];
        gradientLayer.startPoint = CGPointMake(0, 0);
        gradientLayer.endPoint = CGPointMake(1, 1);
        gradientLayer.cornerRadius = 25;
        [mainContainer.layer insertSublayer:gradientLayer atIndex:0];

        // Animate gradient colors for cosmic effect
        CABasicAnimation *gradientAnimation = [CABasicAnimation animationWithKeyPath:@"colors"];
        gradientAnimation.duration = 8.0;
        gradientAnimation.repeatCount = INFINITY;
        gradientAnimation.autoreverses = YES;
        gradientAnimation.toValue = @[
            (id)[UIColor colorWithRed:0.1 green:0.05 blue:0.3 alpha:0.95].CGColor,
            (id)[UIColor colorWithRed:0.2 green:0.1 blue:0.5 alpha:0.95].CGColor,
            (id)[UIColor colorWithRed:0.05 green:0.2 blue:0.4 alpha:0.95].CGColor,
            (id)[UIColor colorWithRed:0.15 green:0.05 blue:0.35 alpha:0.95].CGColor,
            (id)[UIColor colorWithRed:0.05 green:0.15 blue:0.3 alpha:0.95].CGColor
        ];
        [gradientLayer addAnimation:gradientAnimation forKey:@"colorAnimation"];

        // Add moving stars effect
        [self addMovingStarsToContainer:mainContainer];

        // Blur overlay
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
        blurView.alpha = 0.3;
        blurView.layer.cornerRadius = 25;
        blurView.layer.masksToBounds = YES;
        blurView.translatesAutoresizingMaskIntoConstraints = NO;
        [mainContainer addSubview:blurView];

        // Border glow effect
        mainContainer.layer.borderWidth = 2;
        mainContainer.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.4].CGColor;
        mainContainer.layer.shadowColor = [UIColor colorWithRed:0.5 green:0.3 blue:0.9 alpha:1.0].CGColor;
        mainContainer.layer.shadowOffset = CGSizeMake(0, 0);
        mainContainer.layer.shadowOpacity = 0.6;
        mainContainer.layer.shadowRadius = 15;

        // Author title
        UILabel *authorLabel = [[UILabel alloc] init];
        authorLabel.text = @"👨‍💻 Created by ThanhDo1110";
        authorLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBlack];
        authorLabel.textColor = [UIColor whiteColor];
        authorLabel.textAlignment = NSTextAlignmentCenter;
        authorLabel.layer.shadowColor = [UIColor blackColor].CGColor;
        authorLabel.layer.shadowOffset = CGSizeMake(0, 2);
        authorLabel.layer.shadowOpacity = 0.8;
        authorLabel.layer.shadowRadius = 4;
        authorLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [mainContainer addSubview:authorLabel];

        // Subtitle
        UILabel *subtitleLabel = [[UILabel alloc] init];
        subtitleLabel.text = @"⭐ Premium Jailbreak Tweak Developer ⭐";
        subtitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
        subtitleLabel.textAlignment = NSTextAlignmentCenter;
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [mainContainer addSubview:subtitleLabel];

        // Button container
        UIStackView *buttonStack = [[UIStackView alloc] init];
        buttonStack.axis = UILayoutConstraintAxisHorizontal;
        buttonStack.distribution = UIStackViewDistributionFillEqually;
        buttonStack.spacing = 8;
        buttonStack.translatesAutoresizingMaskIntoConstraints = NO;
        [mainContainer addSubview:buttonStack];

        // GitHub button
        UIButton *githubButton = [self createSocialButtonWithTitle:@" GitHub " backgroundColor:[UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.9] action:@selector(openGitHub)];
        [buttonStack addArrangedSubview:githubButton];

        // Telegram button
        UIButton *telegramButton = [self createSocialButtonWithTitle:@"💬 Telegram" backgroundColor:[UIColor colorWithRed:0.2 green:0.6 blue:0.9 alpha:0.9] action:@selector(openTelegram)];
        [buttonStack addArrangedSubview:telegramButton];

        // Website button
        UIButton *websiteButton = [self createSocialButtonWithTitle:@"🌐 Website" backgroundColor:[UIColor colorWithRed:0.9 green:0.5 blue:0.1 alpha:0.9] action:@selector(openWebsite)];
        [buttonStack addArrangedSubview:websiteButton];

        // Constraints
        [NSLayoutConstraint activateConstraints:@[
            // Main container
            [mainContainer.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:10],
            [mainContainer.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-10],
            [mainContainer.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [mainContainer.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],

            // Blur view
            [blurView.leadingAnchor constraintEqualToAnchor:mainContainer.leadingAnchor],
            [blurView.trailingAnchor constraintEqualToAnchor:mainContainer.trailingAnchor],
            [blurView.topAnchor constraintEqualToAnchor:mainContainer.topAnchor],
            [blurView.bottomAnchor constraintEqualToAnchor:mainContainer.bottomAnchor],

            // Author label
            [authorLabel.leadingAnchor constraintEqualToAnchor:mainContainer.leadingAnchor constant:15],
            [authorLabel.trailingAnchor constraintEqualToAnchor:mainContainer.trailingAnchor constant:-15],
            [authorLabel.topAnchor constraintEqualToAnchor:mainContainer.topAnchor constant:15],

            // Subtitle label
            [subtitleLabel.leadingAnchor constraintEqualToAnchor:mainContainer.leadingAnchor constant:15],
            [subtitleLabel.trailingAnchor constraintEqualToAnchor:mainContainer.trailingAnchor constant:-15],
            [subtitleLabel.topAnchor constraintEqualToAnchor:authorLabel.bottomAnchor constant:5],

            // Button stack
            [buttonStack.leadingAnchor constraintEqualToAnchor:mainContainer.leadingAnchor constant:15],
            [buttonStack.trailingAnchor constraintEqualToAnchor:mainContainer.trailingAnchor constant:-15],
            [buttonStack.topAnchor constraintEqualToAnchor:subtitleLabel.bottomAnchor constant:15],
            [buttonStack.bottomAnchor constraintEqualToAnchor:mainContainer.bottomAnchor constant:-15],
            [buttonStack.heightAnchor constraintEqualToConstant:35]
        ]];

 
        dispatch_async(dispatch_get_main_queue(), ^{
            gradientLayer.frame = mainContainer.bounds;
        });

        return cell;
    }

    // Settings Cells
    NSString *key = self.settingsKeys[indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"SettingCell"];
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    CGFloat labelHorizontalPadding = 15.0;
    CGFloat labelVerticalPadding = 10.0;
    CGFloat blurLeftInset = 10.0;
    CGFloat blurRightInset = -80.0;
    CGFloat cornerRadius = 18.0;
    CGFloat toggleContainerWidth = 70.0;

    UIVisualEffectView *effectView = [[UIVisualEffectView alloc] init];
    effectView.effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
    effectView.layer.cornerRadius = cornerRadius;
    effectView.layer.masksToBounds = YES;
    effectView.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:effectView];

    CALayer *borderLayer = [CALayer layer];
    borderLayer.cornerRadius = cornerRadius;
    borderLayer.borderWidth = 1.5;
    borderLayer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.3].CGColor;
    borderLayer.masksToBounds = YES;
    [effectView.layer addSublayer:borderLayer];

    UILabel *textLabel = [[UILabel alloc] init];
    textLabel.text = self.settingsLabels[key];
    textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightHeavy];
    textLabel.textColor = [UIColor whiteColor];
    textLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:textLabel];

    UILabel *detailTextLabel = [[UILabel alloc] init];
    FakeSettings *settings = [FakeSettings shared];
    NSString *originalValue = settings.originalValues[key] ?: @"N/A";
    NSString *fakeValue = settings.settings[key] ?: @"Not configured";

    NSString *truncatedOriginal = originalValue;
    NSString *truncatedFake = fakeValue;
    
    NSInteger maxLength = 18;
    if (originalValue.length > maxLength) {
        truncatedOriginal = [NSString stringWithFormat:@"%@...", [originalValue substringToIndex:maxLength]];
    }
    if (fakeValue.length > maxLength) {
        truncatedFake = [NSString stringWithFormat:@"%@...", [fakeValue substringToIndex:maxLength]];
    }

    NSString *statusIcon = [settings isEnabled:key] ? @"🟢" : @"⚪";
    detailTextLabel.text = [NSString stringWithFormat:@"%@ Original: %@\n🎭 Fake: %@", statusIcon, truncatedOriginal, truncatedFake];
    detailTextLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    detailTextLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.8];
    detailTextLabel.numberOfLines = 2;
    detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    detailTextLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:detailTextLabel];

    UIView *toggleContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, toggleContainerWidth, 35)];
    toggleContainer.backgroundColor = [UIColor clearColor];

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.center = CGPointMake(toggleContainer.bounds.size.width / 2.0, toggleContainer.bounds.size.height / 2.0);
    toggle.on = [settings isEnabled:key];
    toggle.onTintColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1.0];
    toggle.thumbTintColor = [UIColor whiteColor];
    toggle.tag = indexPath.row;
    [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    [toggleContainer addSubview:toggle];
    cell.accessoryView = toggleContainer;

    [NSLayoutConstraint activateConstraints:@[
        [NSLayoutConstraint constraintWithItem:effectView attribute:NSLayoutAttributeLeading relatedBy:NSLayoutRelationEqual toItem:cell.contentView attribute:NSLayoutAttributeLeading multiplier:1.0 constant:blurLeftInset],
        [NSLayoutConstraint constraintWithItem:effectView attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:cell.contentView attribute:NSLayoutAttributeTop multiplier:1.0 constant:labelVerticalPadding],
        [NSLayoutConstraint constraintWithItem:effectView attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:cell.contentView attribute:NSLayoutAttributeBottom multiplier:1.0 constant:-labelVerticalPadding],
        [NSLayoutConstraint constraintWithItem:effectView attribute:NSLayoutAttributeTrailing relatedBy:NSLayoutRelationEqual toItem:cell.contentView attribute:NSLayoutAttributeTrailing multiplier:1.0 constant:-blurRightInset],
        [NSLayoutConstraint constraintWithItem:textLabel attribute:NSLayoutAttributeLeading relatedBy:NSLayoutRelationEqual toItem:effectView attribute:NSLayoutAttributeLeading multiplier:1.0 constant:labelHorizontalPadding],
        [NSLayoutConstraint constraintWithItem:textLabel attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:effectView attribute:NSLayoutAttributeTop multiplier:1.0 constant:labelVerticalPadding],
        [NSLayoutConstraint constraintWithItem:textLabel attribute:NSLayoutAttributeTrailing relatedBy:NSLayoutRelationEqual toItem:effectView attribute:NSLayoutAttributeTrailing multiplier:1.0 constant:-labelHorizontalPadding],
        [NSLayoutConstraint constraintWithItem:detailTextLabel attribute:NSLayoutAttributeLeading relatedBy:NSLayoutRelationEqual toItem:effectView attribute:NSLayoutAttributeLeading multiplier:1.0 constant:labelHorizontalPadding],
        [NSLayoutConstraint constraintWithItem:detailTextLabel attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:textLabel attribute:NSLayoutAttributeBottom multiplier:1.0 constant:3.0],
        [NSLayoutConstraint constraintWithItem:detailTextLabel attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:effectView attribute:NSLayoutAttributeBottom multiplier:1.0 constant:-labelVerticalPadding],
        [NSLayoutConstraint constraintWithItem:detailTextLabel attribute:NSLayoutAttributeTrailing relatedBy:NSLayoutRelationEqual toItem:effectView attribute:NSLayoutAttributeTrailing multiplier:1.0 constant:-labelHorizontalPadding],
    ]];

    return cell;
}

// MARK: - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedbackGenerator impactOccurred];
    }
    
    if (indexPath.section == 0) {
        NSString *key = self.settingsKeys[indexPath.row];
        
        FakeSettings *settings = [FakeSettings shared];
        NSString *originalValue = settings.originalValues[key] ?: @"N/A";
        NSString *fakeValue = settings.settings[key] ?: @"Not configured";
        NSString *label = self.settingsLabels[key] ?: key;
        
        NSString *copyText = [NSString stringWithFormat:@"%@\nOriginal: %@\nFake: %@", label, originalValue, fakeValue];
        
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        pasteboard.string = copyText;
        
        UIAlertController *copyAlert = [UIAlertController alertControllerWithTitle:@"📋 Copied!" 
                                                                           message:[NSString stringWithFormat:@"Copied %@ values to clipboard", label] 
                                                                    preferredStyle:UIAlertControllerStyleAlert];
        
        UIAlertAction *editAction = [UIAlertAction actionWithTitle:@"Edit" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if (@available(iOS 10.0, *)) {
                UIImpactFeedbackGenerator *editFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                [editFeedback impactOccurred];
            }
            [self showEditDialogForKey:key];
        }];
        
        UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
            if (@available(iOS 10.0, *)) {
                UIImpactFeedbackGenerator *okFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                [okFeedback impactOccurred];
            }
        }];
        
        [copyAlert addAction:editAction];
        [copyAlert addAction:okAction];
        [self presentViewController:copyAlert animated:YES completion:nil];
    }
}

// MARK: - Actions

- (void)toggleChanged:(UISwitch *)sender {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *toggleFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [toggleFeedback impactOccurred];
    }
    
    NSString *key = self.settingsKeys[sender.tag];
    FakeSettings *settings = [FakeSettings shared];
    settings.toggles[key] = @(sender.isOn);
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:sender.tag inSection:0]] withRowAnimation:UITableViewRowAnimationFade];
}

- (void)showEditDialogForKey:(NSString *)key {
    FakeSettings *settings = [FakeSettings shared];
    NSString *label = self.settingsLabels[key] ?: key;
    NSString *currentValue = settings.settings[key] ?: @"";
    NSString *originalValue = settings.originalValues[key] ?: @"N/A";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Edit %@", label]
                                                                   message:[NSString stringWithFormat:@"Original: %@\n\nCurrent Value: %@", originalValue, currentValue]
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = currentValue;
        textField.placeholder = @"Enter new fake value...";
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *newValue = alert.textFields.firstObject.text;
        if (newValue != nil) {
            settings.settings[key] = newValue;
            [settings saveSettings];
            [self.tableView reloadData];
        }
    }];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];

    [alert addAction:saveAction];
    [alert addAction:cancelAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)saveAndExit {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *saveFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
        [saveFeedback impactOccurred];
    }
    
    [[FakeSettings shared] saveSettings];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"✅ Settings Saved!" message:@"Settings have been saved." preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)closeSettings {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *closeFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [closeFeedback impactOccurred];
    }
    
    if (settingsWindow) {
        settingsWindow.hidden = YES;
        settingsWindow = nil;
        hasShownSettings = NO;
    }
}

- (void)resetSettings {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *resetFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [resetFeedback impactOccurred];
    }
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🔄 Reset All Settings" message:@"This will clear all fake values and disable all toggles. Are you sure?" preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *resetAction = [UIAlertAction actionWithTitle:@"Reset Everything" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *destructiveFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            [destructiveFeedback impactOccurred];
        }
        
        [[FakeSettings shared] resetSettings];
        [self.tableView reloadData];
        UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"✅ Reset Complete" message:@"All settings have been cleared!" preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if (@available(iOS 10.0, *)) {
                UIImpactFeedbackGenerator *okFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                [okFeedback impactOccurred];
            }
        }];
        [successAlert addAction:okAction];
        [self presentViewController:successAlert animated:YES completion:nil];
    }];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *cancelFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [cancelFeedback impactOccurred];
        }
    }];
    [alert addAction:resetAction];
    [alert addAction:cancelAction];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

// MARK: - Gesture Handler

@interface GestureHandler : NSObject
- (void)handleTripleFingerTap:(UITapGestureRecognizer *)gesture;
- (void)handleFourFingerLongPress:(UILongPressGestureRecognizer *)gesture;
- (void)handleFourFingerShortPress:(UILongPressGestureRecognizer *)gesture;
@end

@implementation GestureHandler
- (void)handleTripleFingerTap:(UITapGestureRecognizer *)gesture {
    if (!hasShownSettings && !settingsWindow) {
        ShowSettingsUI();
    }
}

- (void)handleFourFingerLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        SafeLog(@"Four finger long press detected - showing UI");
        ShowSettingsUI();
        
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            [feedback impactOccurred];
        }
    }
}

- (void)handleFourFingerShortPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        SafeLog(@"Four finger short press detected - showing UI");
        ShowSettingsUI();
        
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [feedback impactOccurred];
        }
    }
}
@end

static GestureHandler *gestureHandler = nil;
static UITapGestureRecognizer *tripleFingerGesture = nil;
static UILongPressGestureRecognizer *fourFingerLongPress = nil;
static UILongPressGestureRecognizer *fourFingerShortPress = nil;

void SetupGestureRecognizer() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = nil;
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *windowScene in [UIApplication sharedApplication].connectedScenes) {
                if (windowScene.activationState == UISceneActivationStateForegroundActive) {
                    keyWindow = windowScene.windows.firstObject;
                    break;
                }
            }
        } else {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            keyWindow = [UIApplication sharedApplication].keyWindow;
            #pragma clang diagnostic pop
        }
        if (!keyWindow) {
            // Try to get any available window
            NSArray *windows = [UIApplication sharedApplication].windows;
            for (UIWindow *window in windows) {
                if (window) {
                    keyWindow = window;
                    break;
                }
            }
        }
        
        if (!keyWindow) {
            SafeLog(@"Warning: Could not find any window to attach gesture recognizer.");
            return;
        }

        if (!gestureHandler) {
            gestureHandler = [[GestureHandler alloc] init];
        }

        if (!tripleFingerGesture) {
            tripleFingerGesture = [[UITapGestureRecognizer alloc] initWithTarget:gestureHandler action:@selector(handleTripleFingerTap:)];
            tripleFingerGesture.numberOfTapsRequired = 2;
            tripleFingerGesture.numberOfTouchesRequired = 4;
            tripleFingerGesture.delaysTouchesBegan = NO;
            tripleFingerGesture.delaysTouchesEnded = NO;
            tripleFingerGesture.cancelsTouchesInView = NO;

            [keyWindow addGestureRecognizer:tripleFingerGesture];
            SafeLog(@"Triple-finger tap gesture recognizer setup complete.");
        }
        
        if (!fourFingerLongPress) {
            fourFingerLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:gestureHandler action:@selector(handleFourFingerLongPress:)];
            fourFingerLongPress.numberOfTouchesRequired = 4;
            fourFingerLongPress.minimumPressDuration = 1.5;
            fourFingerLongPress.allowableMovement = 50;
            fourFingerLongPress.delaysTouchesBegan = NO;
            fourFingerLongPress.delaysTouchesEnded = NO;
            fourFingerLongPress.cancelsTouchesInView = NO;
            
            [keyWindow addGestureRecognizer:fourFingerLongPress];
            SafeLog(@"Four-finger long press gesture recognizer setup complete.");
        }
        
        if (!fourFingerShortPress) {
            fourFingerShortPress = [[UILongPressGestureRecognizer alloc] initWithTarget:gestureHandler action:@selector(handleFourFingerShortPress:)];
            fourFingerShortPress.numberOfTouchesRequired = 4;
            fourFingerShortPress.minimumPressDuration = 0.3;
            fourFingerShortPress.allowableMovement = 80;
            fourFingerShortPress.delaysTouchesBegan = NO;
            fourFingerShortPress.delaysTouchesEnded = NO;
            fourFingerShortPress.cancelsTouchesInView = NO;
            
            [keyWindow addGestureRecognizer:fourFingerShortPress];
            SafeLog(@"Four-finger short press gesture recognizer setup complete.");
        }
    });
}

// MARK: - Show Settings UI

void ShowSettingsUI() {
    if (settingsWindow) {
        settingsWindow.hidden = YES;
        settingsWindow = nil;
        hasShownSettings = NO;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        settingsWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        settingsWindow.windowLevel = UIWindowLevelAlert + 50;
        settingsWindow.backgroundColor = [UIColor clearColor];
        settingsWindow.opaque = NO;
        
        settingsWindow.alpha = 1.0;
        settingsWindow.userInteractionEnabled = YES;

        FakeSettingsViewController *settingsVC = [[FakeSettingsViewController alloc] init];
        settingsWindow.rootViewController = settingsVC;

        [settingsWindow makeKeyAndVisible];
        settingsWindow.hidden = NO;
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [settingsWindow makeKeyAndVisible];
            settingsWindow.windowLevel = UIWindowLevelAlert + 50;
        });
        
        SafeLog(@"Settings UI forcefully presented with highest window level.");
    });
}

// MARK: - Fake UIDevice Hooks

%hook UIDevice
- (NSString *)systemVersion {
    @try {
        FakeSettings *settings = [FakeSettings shared];
        if ([settings isEnabled:@"systemVersion"]) return [settings valueForKey:@"systemVersion"];
        return %orig;
    } @catch(NSException *e) {
        SafeLog(@"[CRASH] UIDevice.systemVersion: %@", e.reason);
        return %orig;
    }
}

- (NSString *)model {
    @try {
        FakeSettings *settings = [FakeSettings shared];
        if ([settings isEnabled:@"deviceModel"]) return [settings valueForKey:@"deviceModel"];
        return %orig;
    } @catch(NSException *e) {
        SafeLog(@"[CRASH] UIDevice.model: %@", e.reason);
        return %orig;
    }
}

- (NSString *)name {
    @try {
        FakeSettings *settings = [FakeSettings shared];
        if ([settings isEnabled:@"deviceName"]) return [settings valueForKey:@"deviceName"];
        return %orig;
    } @catch(NSException *e) {
        SafeLog(@"[CRASH] UIDevice.name: %@", e.reason);
        return %orig;
    }
}

- (NSUUID *)identifierForVendor {
    @try {
        FakeSettings *settings = [FakeSettings shared];
        if ([settings isEnabled:@"identifierForVendor"]) return [[NSUUID alloc] initWithUUIDString:[settings valueForKey:@"identifierForVendor"]];
        return %orig;
    } @catch(NSException *e) {
        SafeLog(@"[CRASH] UIDevice.identifierForVendor: %@", e.reason);
        return %orig;
    }
}
%end

// MARK: - Fake NSBundle Hooks

%hook NSBundle
- (NSString *)bundleIdentifier {
    @try {
        if (self == [NSBundle mainBundle]) {
            FakeSettings *settings = [FakeSettings shared];
            if ([settings isEnabled:@"bundleIdentifier"]) return [settings valueForKey:@"bundleIdentifier"];
        }
        return %orig;
    } @catch(NSException *e) {
        SafeLog(@"[CRASH] NSBundle.bundleIdentifier: %@", e.reason);
        return %orig;
    }
}

- (NSDictionary *)infoDictionary {
    @try {
        NSDictionary *origDict = %orig;
        NSMutableDictionary *dict = origDict ? [origDict mutableCopy] : [NSMutableDictionary dictionary];
        FakeSettings *settings = [FakeSettings shared];

        if ([settings isEnabled:@"appVersion"]) dict[@"CFBundleShortVersionString"] = [settings valueForKey:@"appVersion"];
        if ([settings isEnabled:@"bundleVersion"]) dict[@"CFBundleVersion"] = [settings valueForKey:@"bundleVersion"];
        if ([settings isEnabled:@"displayName"]) dict[@"CFBundleDisplayName"] = [settings valueForKey:@"displayName"];

        return dict;
    } @catch(NSException *e) {
        SafeLog(@"[CRASH] NSBundle.infoDictionary: %@", e.reason);
        return %orig;
    }
}
%end

// MARK: - Fake NSProcessInfo Hook

%hook NSProcessInfo
- (NSString *)operatingSystemVersionString {
    @try {
        FakeSettings *settings = [FakeSettings shared];
        if ([settings isEnabled:@"systemVersion"]) {
            return [NSString stringWithFormat:@"Version %@ (Build %@)",
                   [settings valueForKey:@"systemVersion"],
                   [settings valueForKey:@"bundleVersion"] ?: @"UnknownBuild"];
        }
        return %orig;
    } @catch(NSException *e) {
        SafeLog(@"[CRASH] NSProcessInfo.operatingSystemVersionString: %@", e.reason);
        return %orig;
    }
}
%end

// MARK: - Fake C Functions Hooks

int fake_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    @try {
        FakeSettings *settings = [FakeSettings shared];

        if ([settings isEnabled:@"deviceModel"] && strcmp(name, "hw.machine") == 0) {
            const char *val = [[settings valueForKey:@"deviceModel"] UTF8String];
            size_t len = strlen(val) + 1;
            if (oldp && oldlenp && *oldlenp >= len) {
                strcpy((char *)oldp, val);
                *oldlenp = len;
                return 0;
            } else if (oldlenp) {
                 *oldlenp = len;
                 errno = ENOMEM;
                 return -1;
            }
        }

        if ([settings isEnabled:@"darwinVersion"]) {
            if (strcmp(name, "kern.osrelease") == 0) {
                const char *val = [[settings valueForKey:@"darwinVersion"] UTF8String];
                size_t len = strlen(val) + 1;
                if (oldp && oldlenp && *oldlenp >= len) {
                    strcpy((char *)oldp, val);
                    *oldlenp = len;
                    return 0;
                } else if (oldlenp) {
                    *oldlenp = len;
                    errno = ENOMEM;
                    return -1;
                }
            }
        }
        return sysctlbyname(name, oldp, oldlenp, newp, newlen);
    } @catch(NSException *e) {
        SafeLog(@"[CRASH][sysctlbyname]: %@", e.reason);
        return sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
}

int fake_uname(struct utsname *name) {
    int ret = uname(name);
    @try {
        FakeSettings *settings = [FakeSettings shared];
        if ([settings isEnabled:@"deviceModel"]) {
            NSString *fakeModel = [settings valueForKey:@"deviceModel"];
            if (fakeModel) {
                strncpy(name->machine, [fakeModel UTF8String], sizeof(name->machine) - 1);
                name->machine[sizeof(name->machine) - 1] = '\0';
            }
        }
        if ([settings isEnabled:@"darwinVersion"]) {
            NSString *fakeDarwinVersion = [settings valueForKey:@"darwinVersion"];
            if (fakeDarwinVersion) {
                strncpy(name->release, [fakeDarwinVersion UTF8String], sizeof(name->release) - 1);
                name->release[sizeof(name->release) - 1] = '\0';
            }
        }
    } @catch(NSException *e) {
        SafeLog(@"[CRASH][uname]: %@", e.reason);
    }
    return ret;
}

int fake_getifaddrs(struct ifaddrs **ifap) {
    int ret = getifaddrs(ifap);
    FakeSettings *settings = [FakeSettings shared];
    if ([settings isEnabled:@"wifiIP"] && ret == 0 && ifap && *ifap) {
        @try {
            struct ifaddrs *ifa = *ifap;
            while (ifa) {
                if (ifa->ifa_addr && ifa->ifa_addr->sa_family == AF_INET && strcmp(ifa->ifa_name, "en0") == 0) {
                    struct sockaddr_in *addr = (struct sockaddr_in *)ifa->ifa_addr;
                    if (addr) {
                        const char* fakeIP = [[settings valueForKey:@"wifiIP"] UTF8String];
                        if (inet_pton(AF_INET, fakeIP, &(addr->sin_addr)) >= 0) {
                             SafeLog(@"Fake IP address set for en0 to: %@", [settings valueForKey:@"wifiIP"]);
                        } else {
                             SafeLog(@"Failed to parse fake IP address: %@", [settings valueForKey:@"wifiIP"]);
                        }
                    }
                }
                ifa = ifa->ifa_next;
            }
        } @catch(NSException *e) {
            SafeLog(@"[CRASH][getifaddrs]: %@", e.reason);
        }
    }
    return ret;
}

// MARK: - Fake Jailbreak Detection

%hook NSFileManager
- (BOOL)fileExistsAtPath:(NSString *)path {
    @try {
        FakeSettings *settings = [FakeSettings shared];
        if ([settings isEnabled:@"jailbreak"]) {
            NSArray *jbPaths = @[@"/Applications/Cydia.app", @"/usr/sbin/sshd", @"/bin/bash", @"/etc/apt", @"/private/var/lib/apt/", @"/Library/MobileSubstrate/MobileSubstrate.dylib"];
            if ([jbPaths containsObject:path]) return NO;
        }
        return %orig;
    } @catch(NSException *e) {
        SafeLog(@"[CRASH] NSFileManager.fileExistsAtPath: %@", e.reason);
        return %orig;
    }
}
%end

int fake_stat(const char *path, struct stat *buf) {
    FakeSettings *settings = [FakeSettings shared];
    if ([settings isEnabled:@"jailbreak"] && (strstr(path, "Cydia") || strstr(path, "bash") || strstr(path, "apt") || strstr(path, "MobileSubstrate"))) {
        errno = ENOENT;
        return -1;
    }
    return stat(path, buf);
}

int fake_access(const char *path, int amode) {
    FakeSettings *settings = [FakeSettings shared];
    if ([settings isEnabled:@"jailbreak"] && (strstr(path, "Cydia") || strstr(path, "bash") || strstr(path, "apt") || strstr(path, "MobileSubstrate"))) {
        return -1;
    }
    return access(path, amode);
}

FILE* fake_fopen(const char *path, const char *mode) {
    FakeSettings *settings = [FakeSettings shared];
    if ([settings isEnabled:@"jailbreak"] && (strstr(path, "Cydia") || strstr(path, "bash") || strstr(path, "apt") || strstr(path, "MobileSubstrate"))) {
        return NULL;
    }
    return fopen(path, mode);
}

// // MARK: - UIApplication Hook

// %hook UIApplication
// - (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
//     BOOL result = %orig;
    
//     // Setup gesture recognizer immediately
//     dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
//         SetupGestureRecognizer();
//     });
    
//     // Force show settings UI after 3 seconds
//     dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
//         SafeLog(@"Auto-showing Settings UI after 3 seconds...");
//         ShowSettingsUI();
        
//         // Additional backup attempts to ensure visibility
//         dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
//             if (settingsWindow) {
//                 [settingsWindow makeKeyAndVisible];
//                 settingsWindow.windowLevel = UIWindowLevelAlert + 50;
//             }
//         });
        
//         dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
//             if (settingsWindow) {
//                 [settingsWindow makeKeyAndVisible];
//                 settingsWindow.windowLevel = UIWindowLevelAlert + 50;
//             }
//         });
//     });
    
//     return result;
// }
// %end

// MARK: - Tweak Initialization

%ctor {
    signal(SIGSEGV, CrashHandler);
    signal(SIGBUS, CrashHandler);
    signal(SIGABRT, CrashHandler);

    [FakeSettings shared];

    void *handle = dlopen(NULL, RTLD_NOW);
    if (handle) {
        void *orig_sysctlbyname = dlsym(handle, "sysctlbyname");
        void *orig_uname = dlsym(handle, "uname");
        void *orig_getifaddrs = dlsym(handle, "getifaddrs");
        void *orig_stat = dlsym(handle, "stat");
        void *orig_access = dlsym(handle, "access");
        void *orig_fopen = dlsym(handle, "fopen");

        if (orig_sysctlbyname) MSHookFunction(orig_sysctlbyname, (void *)&fake_sysctlbyname, NULL);
        if (orig_uname) MSHookFunction(orig_uname, (void *)&fake_uname, NULL);
        if (orig_getifaddrs) MSHookFunction(orig_getifaddrs, (void *)&fake_getifaddrs, NULL);
        if (orig_stat) MSHookFunction(orig_stat, (void *)&fake_stat, NULL);
        if (orig_access) MSHookFunction(orig_access, (void *)&fake_access, NULL);
        if (orig_fopen) MSHookFunction(orig_fopen, (void *)&fake_fopen, NULL);

        dlclose(handle);
    } else {
         SafeLog(@"Error opening handle for current executable: %s", dlerror());
    }

    SafeLog(@"🎭 [FakeTweak] ULTRA UI VERSION LOADED! Created by @thanhdo1110");
    SetupGestureRecognizer();
    
    // // Force show UI after 3 seconds from tweak load
    // dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    //     SafeLog(@"Force showing Settings UI from constructor after 3 seconds...");
    //     ShowSettingsUI();
        
    //     // Multiple attempts to ensure visibility
    //     for (int i = 1; i <= 5; i++) {
    //         dispatch_after(dispatch_time(DISPATCH_TIME_NOW, i * 2.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    //             if (settingsWindow) {
    //                 [settingsWindow makeKeyAndVisible];
    //                 settingsWindow.windowLevel = UIWindowLevelAlert + 50;
    //                 settingsWindow.hidden = NO;
    //             }
    //         });
    //     }
    // });
}