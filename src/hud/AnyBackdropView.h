#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 自适应取色那条渲染路径的「取色层」。
///
/// `layerClass` 是私有的 `CABackdropLayer`，它能把**别的 window**（也就是 HUD 背后的
/// 真实画面）采样进来做滤镜 —— 这是普通 layer 做不到的，也是为什么这里必须用
/// `CABackdropLayer` 而不是 `compositingFilter`（混合模式只在自己那棵 layer tree 里
/// 生效，读不到下层 window）。
///
/// 它的输出最后被 `maskView`（一个字形 label）裁成字形，所以**字形里填的就是被滤镜
/// 处理过的背后画面**：滤镜把背后压成纯黑或纯白再翻过来，文字于是永远和背景相反。
@interface AnyBackdropView : UIView

/// 高斯模糊半径（pt）。只决定「取色决定在空间上有多平滑」，**与文字可读性无关**
/// —— 保证可读性的是颜色链里的硬阈值 + 反相。默认 50（与上游一致）。
///
/// 设成 0 可以完全跳过模糊，是这条路径上最省的一档。
@property (nonatomic, assign) CGFloat blurRadius;

/// 实验开关：把「亮度 → 对比度 → 去饱和 → 反相」4 趟全分辨率颜色滤镜，压成 1 趟
/// `kCAFilterColorMatrix`。默认 NO。
///
/// 代价的构成见 `.mm` 里 `- _colorFilters` 的说明：`CABackdropLayer` 是**每帧**重新
/// 采样背后画面的，所以省下来的 3 趟是持续的。矩阵是那 4 趟算术的精确折叠，但少了
/// 「每趟之间夹一次 clamp」这一步，输出会从 8 级灰变成纯黑白（对比度更高、层次更少）。
@property (nonatomic, assign) BOOL compressedFilters;

@end

NS_ASSUME_NONNULL_END
