#import "MainApplicationDelegate.h"
#import "MainApplication.h"
#import "Helium-Swift.h"
#import "../extensions/FontUtils.h"
#import "../widgets/CPUMetricsPublisher.h"

@implementation MainApplicationDelegate

- (instancetype)init {
    if (self = [super init]) {
        os_log_debug(OS_LOG_DEFAULT, "- [MainApplicationDelegate init]");
    }
    return self;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary <UIApplicationLaunchOptionsKey, id> *)launchOptions {
    os_log_debug(OS_LOG_DEFAULT, "- [MainApplicationDelegate application:%{public}@ didFinishLaunchingWithOptions:%{public}@]", application, launchOptions);

    // load fonts from app
    [FontUtils loadFontsFromFolder:[NSString stringWithFormat:@"%@%@", [[NSBundle mainBundle] resourcePath],  @"/fonts"]];
    // load fonts from documents
    [FontUtils loadFontsFromFolder:[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]];
    [FontUtils loadAllFonts];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    [self.window setRootViewController:[[[ContentInterface alloc] init] createUI]];
    [self.window makeKeyAndVisible];

    // Start the CPU-metrics publisher here as well, not only in the HUD.
    //
    // The HUD runs as a *separate* process (`Helium -hud`, started by the
    // LaunchDaemon) and is the one that publishes continuously. But that process is
    // KeepAlive, so after a TrollStore reinstall it keeps running the *old* binary
    // until the device reboots — whereas this main app is relaunched every time the
    // user taps the icon. Starting the publisher here means the shared metrics file
    // and the one-shot IOReport diagnosis refresh as soon as the app is opened,
    // with no reboot needed.
    helium_start_cpu_metrics_publisher();

    return YES;
}

@end