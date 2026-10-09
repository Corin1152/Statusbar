#import <notify.h>
#import <objc/runtime.h>

#import "HUDRootViewController.h"
#import "AnyBackdropView.h"
#import "Helium-Swift.h"

#import "../widgets/WidgetManager.h"
#import "../widgets/CPUMetricsPublisher.h"
#import "../extensions/UsefulFunctions.h"
#import "../extensions/FontUtils.h"
#import "../extensions/EZTimer.h"

#import "../helpers/private_headers/FBSOrientationUpdate.h"
#import "../helpers/private_headers/FBSOrientationObserver.h"
#import "../helpers/private_headers/LSApplicationProxy.h"
#import "../helpers/private_headers/LSApplicationWorkspace.h"
#import "../helpers/private_headers/SpringBoardServices.h"
#import "../helpers/private_headers/UIApplication+Private.h"

#define NOTIFY_UI_LOCKSTATE    "com.apple.springboard.lockstate"
#define NOTIFY_LS_APP_CHANGED  "com.apple.LaunchServices.ApplicationsChanged"

/// 上一次真正画上去的文本，挂在**当时可见的那个** label 上。
///
/// **为什么挂在 label 上而不是存成 ivar**：`createWidgetSetsView` 会把这一整套
/// label / maskLabel / backdrop 整个重建。重建出来的 label 没有关联对象，于是它的
/// 第一帧必然重画 —— 这正是想要的语义，省掉一套「视图重建时记得清缓存」的代码。
/// 存 ivar 反而要额外盯住每一处重建点。
///
/// 两个 label 各存各的（见 `updateLabel`）：一个部件的两条渲染路径只有一条可见，
/// 只有可见的那条会被写、也只有它需要这份缓存。可见性一旦切换（用户在设置里开关
/// 自适应取色、或者设备转了朝向），另一条路径的缓存必须作废 —— 否则它一露面就会
/// 因为「文本没变」而被跳过，拿着上一次的旧字符串凑合。
static const void *kHeliumLastAttributedTextKey = &kHeliumLastAttributedTextKey;

static void LaunchServicesApplicationStateChanged
(CFNotificationCenterRef center,
 void *observer,
 CFStringRef name,
 const void *object,
 CFDictionaryRef userInfo)
{
    /* Application installed or uninstalled */

    BOOL isAppInstalled = NO;
    
    for (LSApplicationProxy *app in [[objc_getClass("LSApplicationWorkspace") defaultWorkspace] allApplications])
    {
        if ([app.applicationIdentifier isEqualToString:@"com.leemin.helium"])
        {
            isAppInstalled = YES;
            break;
        }
    }

    if (!isAppInstalled)
    {
        UIApplication *app = [UIApplication sharedApplication];
        [app terminateWithSuccess];
    }
}

static void SpringBoardLockStatusChanged
(CFNotificationCenterRef center,
 void *observer,
 CFStringRef name,
 const void *object,
 CFDictionaryRef userInfo)
{
    HUDRootViewController *rootViewController = (__bridge HUDRootViewController *)observer;
    NSString *lockState = (__bridge NSString *)name;
    if ([lockState isEqualToString:@NOTIFY_UI_LOCKSTATE])
    {
        mach_port_t sbsPort = SBSSpringBoardServerPort();
        
        if (sbsPort == MACH_PORT_NULL)
            return;
        
        BOOL isLocked;
        BOOL isPasscodeSet;
        SBGetScreenLockStatus(sbsPort, &isLocked, &isPasscodeSet);

        if (!isLocked)
        {
            [rootViewController.view setHidden:NO];
            [rootViewController resumeLoopTimer];
        }
        else
        {
            [rootViewController pauseLoopTimer];
            [rootViewController.view setHidden:YES];
        }
    }
}

static void ReloadHUD
(CFNotificationCenterRef center,
 void *observer,
 CFStringRef name,
 const void *object,
 CFDictionaryRef userInfo)
{
    // NSLog(@"boom ReloadHUD");
    HUDRootViewController *rootViewController = (__bridge HUDRootViewController *)observer;
    // [rootViewController createWidgetSets];
    [rootViewController performReload];
}

#pragma mark - HUDRootViewController

@implementation HUDRootViewController {
    NSMutableDictionary *_userDefaults;
    NSMutableArray <NSLayoutConstraint *> *_constraints;
    FBSOrientationObserver *_orientationObserver;
    // view object arrays
    NSMutableArray <UIVisualEffectView *> *_blurViews;
    NSMutableArray <UILabel *> *_labelViews;
    
    NSMutableArray <AnyBackdropView *> *_backdropViews;
    NSMutableArray <UILabel *> *_maskLabelViews;

    UIView *_contentView;
    
    UIInterfaceOrientation _orientation;

    UIView *_horizontalLine;
    UIView *_verticalLine;
}

- (void)registerNotifications
{
    int token;
    notify_register_dispatch(NOTIFY_RELOAD_HUD, &token, dispatch_get_main_queue(), ^(int token) {
        [self performReload];
    });

    CFNotificationCenterRef darwinCenter = CFNotificationCenterGetDarwinNotifyCenter();
    
    CFNotificationCenterAddObserver(
        darwinCenter,
        (__bridge const void *)self,
        LaunchServicesApplicationStateChanged,
        CFSTR(NOTIFY_LS_APP_CHANGED),
        NULL,
        CFNotificationSuspensionBehaviorCoalesce
    );
    
    CFNotificationCenterAddObserver(
        darwinCenter,
        (__bridge const void *)self,
        SpringBoardLockStatusChanged,
        CFSTR(NOTIFY_UI_LOCKSTATE),
        NULL,
        CFNotificationSuspensionBehaviorCoalesce
    );

    CFNotificationCenterAddObserver(
        darwinCenter,
        (__bridge const void *)self,
        ReloadHUD,
        CFSTR(NOTIFY_RELOAD_HUD),
        NULL,
        CFNotificationSuspensionBehaviorCoalesce
    );
}


#pragma mark - User Default Stuff

- (void)loadUserDefaults:(BOOL)forceReload
{
    if (forceReload || !_userDefaults)
        _userDefaults = [[NSDictionary dictionaryWithContentsOfFile:USER_DEFAULTS_PATH] mutableCopy] ?: [NSMutableDictionary dictionary];
}

/// 去重窗口，见头文件里 `performReload` 的说明。
static CFAbsoluteTime gLastReloadStamp = 0;

- (void)performReload
{
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastReloadStamp < 0.2) {
        return;   // 同一份设置的第二份投递，忽略
    }
    gLastReloadStamp = now;

    [self reloadUserDefaults];
    [self resetLoopTimer];
    [self updateViewConstraints];
}

- (void) reloadUserDefaults
{
    [self loadUserDefaults: YES];
    
    if ([self debugBorder]) {
        _contentView.layer.borderWidth = 1.0;
        [_horizontalLine setHidden:NO];
        [_verticalLine setHidden:NO];
    } else {
        _contentView.layer.borderWidth = 0.0;
        [_horizontalLine setHidden:YES];
        [_verticalLine setHidden:YES];
    }

    NSArray *widgetProps = [self widgetProperties];
    for (int i = 0; i < [widgetProps count]; i++) {
        UIVisualEffectView *blurView = [_blurViews objectAtIndex:i];
        UILabel *labelView = [_labelViews objectAtIndex:i];
        AnyBackdropView *backdropView = [_backdropViews objectAtIndex: i];
        UILabel *maskLabelView = [_maskLabelViews objectAtIndex:i];

        NSDictionary *properties = [widgetProps objectAtIndex:i];
        NSInteger orientationMode = getIntFromDictKey(properties, @"orientationMode", 0);
        NSDictionary *blurDetails = [properties valueForKey:@"blurDetails"] ? [properties valueForKey:@"blurDetails"] : @{@"hasBlur" : @(NO)};
        UIBlurEffect *blurEffect = [
            UIBlurEffect effectWithStyle: getBoolFromDictKey(blurDetails, @"styleDark", true) ? UIBlurEffectStyleSystemMaterialDark : UIBlurEffectStyleSystemMaterialLight
        ];
        BOOL hasBlur = getBoolFromDictKey(blurDetails, @"hasBlur");
        NSInteger blurCornerRadius = getIntFromDictKey(blurDetails, @"cornerRadius", 4);
        double blurAlpha = getDoubleFromDictKey(blurDetails, @"alpha", 1.0);
        NSInteger textAlign = getIntFromDictKey(properties, @"textAlignment", 1);
        NSDictionary *colorDetails = [properties valueForKey:@"colorDetails"] ? [properties valueForKey:@"colorDetails"] : @{@"usesCustomColor" : @(NO)};
        BOOL usesCustomColor = getBoolFromDictKey(colorDetails, @"usesCustomColor");
        UIColor *textColor = [UIColor whiteColor];
        if (usesCustomColor && [colorDetails valueForKey:@"color"]) {
            NSData *customColorData = [colorDetails valueForKey:@"color"];
            textColor = [NSKeyedUnarchiver unarchiveObjectWithData:customColorData];
        }
        NSString *fontName = getStringFromDictKey(properties, @"fontName", @"System Font");
        UIFont *textFont = [FontUtils loadFontWithName:fontName size: getDoubleFromDictKey(properties, @"fontSize", 10) bold: getBoolFromDictKey(properties, @"textBold") italic: getBoolFromDictKey(properties, @"textItalic")];
        double textAlpha = getDoubleFromDictKey(properties, @"textAlpha", 1.0);
        BOOL dynamicColor = getBoolFromDictKey(properties, @"dynamicColor", true);
        
        labelView.textAlignment = (NSTextAlignment)textAlign;
        labelView.font = textFont;
        maskLabelView.textAlignment = (NSTextAlignment)textAlign;
        maskLabelView.font = textFont;
        maskLabelView.textColor = [UIColor whiteColor];

        if (dynamicColor) {
            [blurView setEffect:nil];
            [blurView setHidden:YES];
            [labelView setHidden:YES];
            [backdropView setHidden:NO];
            [maskLabelView setHidden:NO];
            maskLabelView.alpha = textAlpha;
        } else {
            labelView.textColor = textColor;
            labelView.alpha = textAlpha;
            [labelView setHidden:NO];
            [backdropView setHidden:YES];
            [maskLabelView setHidden:YES];
            if (hasBlur) {
                [blurView setEffect:blurEffect];
                [blurView setHidden:NO];
                blurView.layer.cornerRadius = blurCornerRadius;
                blurView.alpha = blurAlpha;
            } else {
                [blurView setEffect:nil];
                [blurView setHidden:YES];
            }
        }

        if ((orientationMode == 1 && [self isLandscapeOrientation])
            || (orientationMode == 2 && ![self isLandscapeOrientation])) {
            [blurView setHidden:YES];
            [labelView setHidden:YES];
            [backdropView setHidden:YES];
            [maskLabelView setHidden:YES];
        }

        if ([self debugBorder]) {
            labelView.layer.borderWidth = 1.0;
            // backdropView.layer.borderWidth = 1.0;
            maskLabelView.layer.borderWidth = 1.0;
        } else {
            labelView.layer.borderWidth = 0.0;
            // backdropView.layer.borderWidth = 0.0;
            maskLabelView.layer.borderWidth = 0.0;
        }

        // 上面这一段刚把「哪一条渲染路径可见」重新定过（`dynamicColor` 可能被用户
        // 改了，也可能只是别的属性变了）。两条路径的「上次画上去的文本」都作废：
        // 只有可见的那条会被写（见 `updateLabel`），另一条本来就没跟上，缓存里那份
        // 已经不能代表它的真实内容了 —— 留着就会在它下次露面时把重画跳掉。
        objc_setAssociatedObject(labelView, kHeliumLastAttributedTextKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(maskLabelView, kHeliumLastAttributedTextKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (BOOL) debugBorder
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey: @"debugBorder"];
    return mode ? [mode boolValue] : NO;
}

- (NSString*) apiKey
{
    [self loadUserDefaults:NO];
    NSString *apiKey = [_userDefaults objectForKey: @"apiKey"];
    return apiKey ? apiKey : @"";
}

- (NSString*) dateLocale
{
    [self loadUserDefaults:NO];
    NSString *locale = [_userDefaults objectForKey: @"dateLocale"];
    return locale ? locale : @"en_US";
}

- (NSArray*) widgetProperties
{
    [self loadUserDefaults: NO];
    NSArray *properties = [_userDefaults objectForKey: @"widgetProperties"];
    return properties;
}

- (BOOL) isLandscapeOrientation
{
    BOOL isLandscape;
    if (_orientation == UIInterfaceOrientationUnknown) {
        isLandscape = CGRectGetWidth(self.view.bounds) > CGRectGetHeight(self.view.bounds);
    } else {
        isLandscape = UIInterfaceOrientationIsLandscape(_orientation);
    }
    return isLandscape;
}

#pragma mark - Initialization and Deallocation

- (instancetype)init
{
    self = [super init];
    if (self) {
        // load fonts from app
        [FontUtils loadFontsFromFolder:[NSString stringWithFormat:@"%@%@", [[NSBundle mainBundle] resourcePath],  @"/fonts"]];
        // load fonts from documents
        [FontUtils loadFontsFromFolder:[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]];
        _constraints = [NSMutableArray array];
        _blurViews = [NSMutableArray array];
        _labelViews = [NSMutableArray array];
        _backdropViews = [NSMutableArray array];
        _maskLabelViews = [NSMutableArray array];
        _orientationObserver = [[objc_getClass("FBSOrientationObserver") alloc] init];
        __weak HUDRootViewController *weakSelf = self;
        [_orientationObserver setHandler:^(FBSOrientationUpdate *orientationUpdate) {
            HUDRootViewController *strongSelf = weakSelf;
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf updateOrientation:(UIInterfaceOrientation)orientationUpdate.orientation animateWithDuration:orientationUpdate.duration];
            });
        }];
        [self registerNotifications];
    }
    return self;
}

- (void)dealloc
{
    [_orientationObserver invalidate];
}

#pragma mark - HUD UI Main Functions

- (void) viewDidLoad
{
    [super viewDidLoad];    
    // MARK: Main Content View
    _contentView = [[UIView alloc] init];
    _contentView.backgroundColor = [UIColor clearColor];
    _contentView.translatesAutoresizingMaskIntoConstraints = NO;
    _contentView.layer.borderColor = [UIColor redColor].CGColor;
    [_contentView setUserInteractionEnabled:YES];
    [self.view addSubview:_contentView];

    _horizontalLine = [[UIView alloc] initWithFrame: CGRectZero];
    _horizontalLine.backgroundColor = [UIColor redColor];
    _horizontalLine.translatesAutoresizingMaskIntoConstraints = NO;
    [_horizontalLine setHidden:YES];
    [_contentView addSubview:_horizontalLine];

    _verticalLine = [[UIView alloc] initWithFrame: CGRectZero];
    _verticalLine.backgroundColor = [UIColor redColor];
    _verticalLine.translatesAutoresizingMaskIntoConstraints = NO;
    [_verticalLine setHidden:YES];
    [_contentView addSubview:_verticalLine];

    [self createWidgetSetsView];
    // Publish this HUD's CPU readings to the shared file so SysProbe can show the
    // same numbers instead of sampling on its own (see CPUMetricsPublisher.mm).
    helium_start_cpu_metrics_publisher();
    notify_post(NOTIFY_RELOAD_HUD);
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    notify_post(NOTIFY_LAUNCHED_HUD);
}

#pragma mark - Timer and View Updating

/// 每个 **widget set** 一个定时器，而不是每个部件一个。
///
/// `updateInterval` 本来就是 set 级的属性（`WidgetSetStruct.updateInterval`），
/// 一个 set 里的所有部件共享同一个间隔 —— 那它们就没有理由各自占一个
/// `dispatch_source`。原来每个部件一个，于是同一个 set 里的 N 个部件各自
/// `dispatch_sync` 回主线程一次，而每个 timer 是用 `dispatch_walltime(NULL, 0)` 各自
/// 起算的、相位互不相同（leeway 又是 10%），所以这 N 次唤醒在时间上永远是散开的：
/// 一个 set 有 4 个部件，就是每周期 4 次主线程唤醒、4 轮「CoreText 排版 + 帧尺寸
/// 调整 + 遮罩重设」，CA 也就提交 4 次。合成一个之后是 1 次。
///
/// 合并顺带还有一个好处：同一个 tick 里几个部件的取值是在**同一次**主线程 pass 上
/// 做的，于是 `cpuBusyFractions` 的 0.25 s 缓存、`getBatteryInfo` 的短缓存真的被
/// 复用上了 —— 原来它们各自落在不同的 pass 里，缓存形同虚设。
- (void)resetLoopTimer
{
    NSArray *widgetProps = [self widgetProperties];
    for (int i = 0; i < [widgetProps count]; i++) {
        UIVisualEffectView *blurView = [_blurViews objectAtIndex:i];
        UILabel *labelView = [_labelViews objectAtIndex:i];
        AnyBackdropView *backdropView = [_backdropViews objectAtIndex: i];
        UILabel *maskLabelView = [_maskLabelViews objectAtIndex:i];

        NSDictionary *properties = [widgetProps objectAtIndex:i];
        if (!labelView || !maskLabelView || !properties)
            break;
        NSArray *identifiers = [properties objectForKey: @"widgetIDs"] ? [properties objectForKey: @"widgetIDs"] : @[];
        double fontSize = [properties objectForKey: @"fontSize"] ? [[properties objectForKey: @"fontSize"] doubleValue] : 10.0;
        double updateInterval = getDoubleFromDictKey(properties, @"updateInterval", 1.0);
        BOOL isEnabled = getBoolFromDictKey(properties, @"isEnabled");
        BOOL autoResizes = getBoolFromDictKey(properties, @"autoResizes");
        float width = getDoubleFromDictKey(properties, @"scale", 50.0);
        float height = getDoubleFromDictKey(properties, @"scaleY", 12.0);
        NSString *timerName = [NSString stringWithFormat:@"widgetset%d", i];
        if (isEnabled) {
            [[EZTimer shareInstance] timer:timerName timerInterval:updateInterval leeway:0.1 resumeType:EZTimerResumeTypeNow queue:EZTimerQueueTypeConcurrent queueName:@"update" repeats:YES action:^(NSString *name) {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [self updateLabel: labelView updateMaskLabel: maskLabelView backdropView: backdropView identifiers: identifiers fontSize: fontSize autoResizes: autoResizes width: width height: height];
                });
            }];
        } else {
            [blurView setEffect:nil];
            [blurView setHidden:YES];
            [labelView setHidden:YES];
            [backdropView setHidden:YES];
            [maskLabelView setHidden:YES];
            [[EZTimer shareInstance] cancel:timerName];
        }
    }
}

/// 缓存键 `kHeliumLastAttributedTextKey` 声明在文件开头，见那里的说明。
///
/// 只画**当前可见**的那一条渲染路径。
///
/// 每个部件同时有两条路径，`reloadUserDefaults` 保证任意时刻至多只有一条可见：
///
///   dynamicColor == YES（默认）→ backdropView + maskLabel 可见，label 隐藏；
///   dynamicColor == NO         → label 可见，backdrop 与 maskLabel 隐藏。
///
/// 原来两条都写，于是每 tick 白付一份代价 —— 而且是两份**性质完全不同**的代价：
///
///   * 写 `label` 会 invalidate 它的 intrinsicContentSize，`_contentView` 上那
///     ~6N 条约束于是要整轮重解一次 Auto Layout；
///   * 写 `maskLabel` 会换掉 `CABackdropLayer` 的遮罩，那一层挂着 5 个 CAFilter
///     （半径 50 的高斯模糊 + 亮度 / 对比度 / 饱和度 / 反相），遮罩一变就要重新
///     合成一次。
///
/// 默认配置下可见的是 backdrop 那条（`dynamicColor` 默认 YES），也就是说原来每一个
/// 部件每 tick 都在**额外**触发一次完整的 Auto Layout，画在一个没人看得见的 label 上。
///
/// 两条都不可见时（这个部件被设成只在另一个朝向显示）退到写 `maskLabel`：它不在
/// Auto Layout 引擎里（它只是 backdropView 的 maskView，没有任何约束），而
/// backdropView 隐藏时遮罩根本不会被合成 —— 所以这一次几乎不要钱，又能保证转回该
/// 朝向时文本是新的。
- (void) updateLabel:(UILabel *) label updateMaskLabel:(UILabel *) maskLabel backdropView:(AnyBackdropView *) backdropView identifiers:(NSArray *) identifiers fontSize:(double) fontSize autoResizes:(BOOL) autoResizes width:(CGFloat) width height:(CGFloat) height
{
#if DEBUG
    os_log_debug(OS_LOG_DEFAULT, "updateLabel");
#endif
    UILabel *live;
    if (!backdropView.hidden && !maskLabel.hidden) {
        live = maskLabel;
    } else if (!label.hidden) {
        live = label;
    } else {
        live = maskLabel;
        // 转回该朝向时真正会显示的是 label（如果用户把自适应取色关了），必须重新
        // 画，不能拿旧文本凑合。这里没写它，就把它的缓存作废。
        objc_setAssociatedObject(label, kHeliumLastAttributedTextKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSAttributedString *attributedText = formattedAttributedString(identifiers, fontSize, label.textColor, [self apiKey], [self dateLocale]);
    if (!attributedText)
        return;

    // 内容一个字都没变就整个跳过。
    //
    // `setAttributedText:` **无条件**把 label 标成需要重画，CoreText 于是从头排一遍版
    // —— 每个 widget 每秒两次（正文一次、作为 `maskView` 的 maskLabel 再一次），
    // 哪怕文本逐字节相同。状态栏上真正每秒都在动的只有 CPU 占用、温度那几个数字；
    // 时间、日期、运营商、信号格这些是静的，跳过它们等于把常驻 HUD 稳态里最大的一块
    // 排版开销直接砍掉。
    //
    // 比较放在 `setAttributedText:` **之前**，代价是一次很短的字符串加属性字典比对，
    // 比它省下的那次排版便宜几个数量级；没命中也只是白比一次。
    //
    // 缓存挂在**实际被写的那一个** label 上（见 `kHeliumLastAttributedTextKey`）：
    // 两条路径各有各的缓存，谁可见就只维护谁。
    NSAttributedString *drawn = objc_getAssociatedObject(live, kHeliumLastAttributedTextKey);
    if (drawn && [drawn isEqualToAttributedString: attributedText]) {
        if (autoResizes) {
            // `sizeThatFits:` 的结果只取决于文本，文本没变尺寸就没变。
            return;
        }
        // `autoResizes == NO` 时 frame 是按设置里的宽高**显式**写的，那个值可能在两次
        // 调用之间被改过（用户在设置里调了缩放），所以这里还要再比一次尺寸。
        if (CGSizeEqualToSize(maskLabel.frame.size, CGSizeMake(width, height)))
            return;
    }
    objc_setAssociatedObject(live, kHeliumLastAttributedTextKey, attributedText,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // NSLog(@"boom attr:%@", attributedText);
    [live setAttributedText: attributedText];

    // 尺寸一律写在 `maskLabel` 上，不管刚才文本写进了谁 —— 这是原来就有的行为，
    // 不能改：`label` 上有 `updateViewConstraints` 建的宽高约束，直接给它写 frame
    // 会跟 Auto Layout 打架（下一轮 layout 会把 frame 覆盖回去）。
    if (autoResizes) {
        [self useSizeThatFitsZeroWithLabel:maskLabel];
    } else {
        [self useSizeThatFitsCustomWithLabel:maskLabel width: width height: height];
    }
}

- (void) useSizeThatFitsZeroWithLabel:(UILabel *)label{
    CGSize size = [label sizeThatFits:CGSizeZero];
    label.frame = CGRectMake(label.frame.origin.x, label.frame.origin.y, size.width, size.height);
}

- (void) useSizeThatFitsCustomWithLabel:(UILabel *)label width:(CGFloat) width height:(CGFloat) height{
    // CGSize size = [label sizeThatFits:CGSizeMake(width, height)];
    label.frame = CGRectMake(label.frame.origin.x, label.frame.origin.y, width, height);
}

- (void)pauseLoopTimer
{
    NSArray *widgetProps = [self widgetProperties];
    for (int i = 0; i < [widgetProps count]; i++) {
        NSDictionary *properties = [widgetProps objectAtIndex:i];
        if (!getBoolFromDictKey(properties, @"isEnabled"))
            continue;
        [[EZTimer shareInstance] pause:[NSString stringWithFormat:@"widgetset%d", i]];
    }

    // 发布器跟着一起停。
    //
    // 原来锁屏只停了渲染定时器，发布器照旧每秒跑一轮 —— 忙循环测频、算占用、写文件。
    // 那些工作的**唯一**消费者是 SysProbe（HUD 自己的部件读的是进程内值），而锁屏时
    // 负一屏不可能在屏幕上。所以这一整条链在锁屏期间是纯耗电。
    //
    // 解锁时 `resumeLoopTimer` 会把它恢复并立刻补一拍，见那里的注释。
    helium_set_cpu_metrics_publisher_paused(YES);
}

- (void)resumeLoopTimer
{
    NSArray *widgetProps = [self widgetProperties];
    for (int i = 0; i < [widgetProps count]; i++) {
        NSDictionary *properties = [widgetProps objectAtIndex:i];
        if (!getBoolFromDictKey(properties, @"isEnabled"))
            continue;
        [[EZTimer shareInstance] resume:[NSString stringWithFormat:@"widgetset%d", i]];
    }

    // 恢复发布器；它内部会立刻补一次发布，所以文件在解锁的那一刻就是新鲜的。
    helium_set_cpu_metrics_publisher_paused(NO);
}

- (void)viewSafeAreaInsetsDidChange
{
    [super viewSafeAreaInsetsDidChange];
    [self updateViewConstraints];
}

- (void)createWidgetSetsView
{
    // MARK: Create the Widgets
    // MIGHT NEED OPTIMIZATION
    for (NSDictionary *properties in [self widgetProperties]) {
        // create the blur
        NSDictionary *blurDetails = [properties valueForKey:@"blurDetails"] ? [properties valueForKey:@"blurDetails"] : @{@"hasBlur" : @(NO)};
        UIBlurEffect *blurEffect = [
            UIBlurEffect effectWithStyle: getBoolFromDictKey(blurDetails, @"styleDark", true) ? UIBlurEffectStyleSystemMaterialDark : UIBlurEffectStyleSystemMaterialLight
        ];
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        blurView.layer.masksToBounds = YES;
        blurView.translatesAutoresizingMaskIntoConstraints = NO;
        [_contentView addSubview:blurView];
        [_blurViews addObject:blurView];
        // create the label
        UILabel *labelView = [[UILabel alloc] initWithFrame: CGRectZero];
        labelView.numberOfLines = 0;
        labelView.lineBreakMode = NSLineBreakByWordWrapping;
        labelView.translatesAutoresizingMaskIntoConstraints = NO;
        labelView.layer.borderColor = [UIColor redColor].CGColor;
        [labelView setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisVertical];
        [_contentView addSubview:labelView];
        [_labelViews addObject:labelView];

        // MARK: Adaptive Color Backdrop
        // create backdrop view
        AnyBackdropView *backdropView = [[AnyBackdropView alloc] init];
        backdropView.translatesAutoresizingMaskIntoConstraints = NO;
        backdropView.layer.borderColor = [UIColor redColor].CGColor;
        [_contentView addSubview:backdropView];
        [_backdropViews addObject:backdropView];

        // create the mask label
        UILabel *maskLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        maskLabel.numberOfLines = 0;
        maskLabel.lineBreakMode = NSLineBreakByWordWrapping;
        maskLabel.translatesAutoresizingMaskIntoConstraints = NO;
        maskLabel.layer.borderColor = [UIColor redColor].CGColor;
        [maskLabel setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisVertical];
        [backdropView setMaskView:maskLabel];
        [_maskLabelViews addObject:maskLabel];
    }
}

- (void)updateViewConstraints
{
    [NSLayoutConstraint deactivateConstraints:_constraints];
    [_constraints removeAllObjects];

    BOOL isPad = ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad);
    UILayoutGuide *layoutGuide = self.view.safeAreaLayoutGuide;
    
    // code from Lessica/TrollSpeed
    if ([self isLandscapeOrientation])
    {
        CGFloat notchHeight;
        CGFloat paddingNearNotch;
        CGFloat paddingFarFromNotch;

        notchHeight = CGRectGetMinY(layoutGuide.layoutFrame);
        paddingNearNotch = (notchHeight > 30) ? notchHeight - 16 : 4;
        paddingFarFromNotch = (notchHeight > 30) ? -24 : -4;

        [_constraints addObjectsFromArray:@[
            [_contentView.leadingAnchor constraintEqualToAnchor:layoutGuide.leadingAnchor constant:(_orientation == UIInterfaceOrientationLandscapeLeft ? -paddingFarFromNotch : paddingNearNotch)],
            [_contentView.trailingAnchor constraintEqualToAnchor:layoutGuide.trailingAnchor constant:(_orientation == UIInterfaceOrientationLandscapeLeft ? -paddingNearNotch : paddingFarFromNotch)],
        ]];

        CGFloat minimumLandscapeTopConstant = 0;
        CGFloat minimumLandscapeBottomConstant = 0;

        minimumLandscapeTopConstant = (isPad ? 30 : 10);
        minimumLandscapeBottomConstant = (isPad ? -34 : -14);

        /* Fixed Constraints */
        [_constraints addObjectsFromArray:@[
            [_contentView.topAnchor constraintGreaterThanOrEqualToAnchor:self.view.topAnchor constant:minimumLandscapeTopConstant],
            [_contentView.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.bottomAnchor constant:minimumLandscapeBottomConstant],
        ]];

        /* Flexible Constraint */
        NSLayoutConstraint *_topConstraint = [_contentView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:minimumLandscapeTopConstant];
        _topConstraint.priority = UILayoutPriorityDefaultLow;

        [_constraints addObject:_topConstraint];
    }
    else
    {
        [_constraints addObjectsFromArray:@[
            [_contentView.leadingAnchor constraintEqualToAnchor:layoutGuide.leadingAnchor],
            [_contentView.trailingAnchor constraintEqualToAnchor:layoutGuide.trailingAnchor],
        ]];

        CGFloat minimumTopConstraintConstant = 0;
        CGFloat minimumBottomConstraintConstant = 0;

        if (CGRectGetMinY(layoutGuide.layoutFrame) >= 51) {
            minimumTopConstraintConstant = -8;
            minimumBottomConstraintConstant = -4;
        } else if (CGRectGetMinY(layoutGuide.layoutFrame) > 30) {
            minimumTopConstraintConstant = -12;
            minimumBottomConstraintConstant = -4;
        } else {
            minimumTopConstraintConstant = (isPad ? 30 : 20);
            minimumBottomConstraintConstant = -20;
        }

        /* Fixed Constraints */
        [_constraints addObjectsFromArray:@[
            [_contentView.topAnchor constraintGreaterThanOrEqualToAnchor:layoutGuide.topAnchor constant:minimumTopConstraintConstant],
            [_contentView.bottomAnchor constraintLessThanOrEqualToAnchor:layoutGuide.bottomAnchor constant:minimumBottomConstraintConstant],
        ]];

        /* Flexible Constraint */
        NSLayoutConstraint *_topConstraint = [_contentView.topAnchor constraintEqualToAnchor:layoutGuide.topAnchor constant:minimumTopConstraintConstant];
        _topConstraint.priority = UILayoutPriorityDefaultLow;

        [_constraints addObject:_topConstraint];
    }

    // MARK: Set Label Constraints
    NSArray *widgetProps = [self widgetProperties];
    // DEFINITELY NEEDS OPTIMIZATION
    for (int i = 0; i < [widgetProps count]; i++) {
        UIVisualEffectView *blurView = [_blurViews objectAtIndex:i];
        UILabel *labelView = [_labelViews objectAtIndex:i];
        AnyBackdropView *backdropView = [_backdropViews objectAtIndex:i];
        // UILabel *maskLabelView = [_maskLabelViews objectAtIndex:i];
        NSDictionary *properties = [widgetProps objectAtIndex:i];
        if (!blurView || !labelView || !properties)
            break;
        if (!getBoolFromDictKey(properties, @"isEnabled"))
            continue;
        double offsetPX = getDoubleFromDictKey(properties, @"offsetPX");
        double offsetPY = getDoubleFromDictKey(properties, @"offsetPY");
        double offsetLX = getDoubleFromDictKey(properties, @"offsetLX");
        double offsetLY = getDoubleFromDictKey(properties, @"offsetLY");
        NSInteger anchorSide = getIntFromDictKey(properties, @"anchor");
        NSInteger anchorYSide = getIntFromDictKey(properties, @"anchorY");

        // set the vertical anchor
        if (anchorYSide == 1) {
            [_constraints addObject:[labelView.centerYAnchor constraintEqualToAnchor:_contentView.centerYAnchor constant: ([self isLandscapeOrientation] ? offsetLY : offsetPY)]];
        } else if (anchorYSide == 0) {
            [_constraints addObject:[labelView.topAnchor constraintEqualToAnchor:_contentView.topAnchor constant: ([self isLandscapeOrientation] ? offsetLY : offsetPY)]];
        } else {
            [_constraints addObject:[labelView.bottomAnchor constraintEqualToAnchor:_contentView.bottomAnchor constant: ([self isLandscapeOrientation] ? offsetLY : offsetPY)]];
        }
        // set the horizontal anchor
        if (anchorSide == 1) {
            [_constraints addObject:[labelView.centerXAnchor constraintEqualToAnchor:_contentView.centerXAnchor constant: ([self isLandscapeOrientation] ? offsetLX : offsetPX)]];
        } else if (anchorSide == 0) {
            [_constraints addObject:[labelView.leadingAnchor constraintEqualToAnchor:_contentView.leadingAnchor constant: ([self isLandscapeOrientation] ? offsetLX : offsetPX)]];
        } else {
            [_constraints addObject:[labelView.trailingAnchor constraintEqualToAnchor:_contentView.trailingAnchor constant: ([self isLandscapeOrientation] ? -offsetLX : -offsetPX)]];
        }

        // set the width
        if (!getBoolFromDictKey(properties, @"autoResizes")) {
            [_constraints addObject:[labelView.widthAnchor constraintEqualToConstant:getDoubleFromDictKey(properties, @"scale", 50.0)]];
            [_constraints addObject:[labelView.heightAnchor constraintEqualToConstant:getDoubleFromDictKey(properties, @"scaleY", 12.0)]];
        }
        
        [_constraints addObjectsFromArray:@[
            [blurView.topAnchor constraintEqualToAnchor:backdropView.topAnchor constant:-2],
            [blurView.leadingAnchor constraintEqualToAnchor:backdropView.leadingAnchor constant:-4],
            [blurView.trailingAnchor constraintEqualToAnchor:backdropView.trailingAnchor constant:4],
            [blurView.bottomAnchor constraintEqualToAnchor:backdropView.bottomAnchor constant:2],
        ]];
        
        [_constraints addObjectsFromArray:@[
            [blurView.topAnchor constraintEqualToAnchor:labelView.topAnchor constant:-2],
            [blurView.leadingAnchor constraintEqualToAnchor:labelView.leadingAnchor constant:-4],
            [blurView.trailingAnchor constraintEqualToAnchor:labelView.trailingAnchor constant:4],
            [blurView.bottomAnchor constraintEqualToAnchor:labelView.bottomAnchor constant:2],
        ]];
    }

    [_constraints addObjectsFromArray:@[
        [_horizontalLine.centerYAnchor constraintEqualToAnchor:_contentView.centerYAnchor],
        [_horizontalLine.widthAnchor constraintEqualToAnchor:_contentView.widthAnchor],
        [_horizontalLine.heightAnchor constraintEqualToConstant:1]
    ]];
    
    [_constraints addObjectsFromArray:@[
        [_verticalLine.centerXAnchor constraintEqualToAnchor:_contentView.centerXAnchor],
        [_verticalLine.widthAnchor constraintEqualToConstant:1],
        [_verticalLine.heightAnchor constraintEqualToAnchor:_contentView.heightAnchor]
    ]];
    
    [NSLayoutConstraint activateConstraints:_constraints];
    [super updateViewConstraints];
}

static inline CGFloat orientationAngle(UIInterfaceOrientation orientation)
{
    switch (orientation) {
        case UIInterfaceOrientationPortraitUpsideDown:
            return M_PI;
        case UIInterfaceOrientationLandscapeLeft:
            return -M_PI_2;
        case UIInterfaceOrientationLandscapeRight:
            return M_PI_2;
        default:
            return 0;
    }
}

static inline CGRect orientationBounds(UIInterfaceOrientation orientation, CGRect bounds)
{
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:
        case UIInterfaceOrientationLandscapeRight:
            return CGRectMake(0, 0, bounds.size.height, bounds.size.width);
        default:
            return bounds;
    }
}

- (void)updateOrientation:(UIInterfaceOrientation)orientation animateWithDuration:(NSTimeInterval)duration
{
    __weak typeof(self) weakSelf = self;
    NSArray *widgetProps = [weakSelf widgetProperties];
    for (int i = 0; i < [widgetProps count]; i++) {
        UIVisualEffectView *blurView = [_blurViews objectAtIndex:i];
        UILabel *labelView = [_labelViews objectAtIndex:i];
        AnyBackdropView *backdropView = [_backdropViews objectAtIndex: i];
        UILabel *maskLabelView = [_maskLabelViews objectAtIndex:i];

        NSDictionary *properties = [widgetProps objectAtIndex:i];
        NSInteger orientationMode = getIntFromDictKey(properties, @"orientationMode", 0);
        BOOL isEnabled = getBoolFromDictKey(properties, @"isEnabled");
        BOOL dynamicColor = getBoolFromDictKey(properties, @"dynamicColor", true);
        if (isEnabled) {
            switch (orientationMode) {
                // Portrait
                case 1: {
                    if (UIInterfaceOrientationIsLandscape(orientation)) {
                        [blurView setHidden:YES];
                        [labelView setHidden:YES];
                        [backdropView setHidden:YES];
                        [maskLabelView setHidden:YES];
                    } else {
                        if (dynamicColor) {
                            [backdropView setHidden:NO];
                            [maskLabelView setHidden:NO];
                        } else {
                            [blurView setHidden:NO];
                            [labelView setHidden:NO];
                        }
                    }
                }break;
                // Landscape
                case 2: {
                    if (UIInterfaceOrientationIsLandscape(orientation)) {
                        if (dynamicColor) {
                            [backdropView setHidden:NO];
                            [maskLabelView setHidden:NO];
                        } else {
                            [blurView setHidden:NO];
                            [labelView setHidden:NO];
                        }
                    } else {
                        [blurView setHidden:YES];
                        [labelView setHidden:YES];
                        [backdropView setHidden:YES];
                        [maskLabelView setHidden:YES];
                    }
                }break;
            }
        }
    }

    if (orientation == _orientation) {
        return;
    }

    _orientation = orientation;

    CGRect bounds = orientationBounds(orientation, [UIScreen mainScreen].bounds);
    [self.view setNeedsUpdateConstraints];
    [self.view setHidden:YES];
    [self.view setBounds:bounds];

    [UIView animateWithDuration:duration animations:^{
        [weakSelf.view setTransform:CGAffineTransformMakeRotation(orientationAngle(orientation))];
    } completion:^(BOOL finished) {
        [weakSelf.view setHidden:NO];
    }];
}

@end
