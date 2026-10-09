#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HUDRootViewController: UIViewController
- (void)resetLoopTimer;
- (void)pauseLoopTimer;
- (void)resumeLoopTimer;
- (void)reloadUserDefaults;
/// 重载设置：读默认值 → 重排定时器 → 重建约束。
///
/// 单独抽出来是因为**同一个 `NOTIFY_RELOAD_HUD` 会被收到两次**：
/// `registerNotifications` 既用 `notify_register_dispatch` 注册了一次，又用
/// `CFNotificationCenterAddObserver` 在 Darwin 通知中心注册了一次，而
/// `notify_post` 两个都会投递。于是每次改设置（以及 HUD 启动时那一次 post）都会
/// 把这三步整个跑两遍 —— 其中 `updateViewConstraints` 要 deactivate/activate
/// 全部 ~6N 条约束。这里做一个 200 ms 的去重窗口，比赌哪一条注册路径更可靠要稳。
- (void)performReload;
@end

NS_ASSUME_NONNULL_END