#import "AnyBackdropView.h"
#import "../helpers/private_headers/CAFilter.h"

/// 上游写死的模糊半径。保留成默认值，观感与 0.26 及以前完全一致。
static const CGFloat kHeliumDefaultBlurRadius = 50.0;

/// 颜色链的参数，来自 `Lessica/TrollSpeed` 的调校：亮度 −28.5% 把阈值从 0.5 抬到
/// 0.785（推导见 `- _colorFilters`），对比度 1000× 把阈值做成硬切。
static const double kHeliumBrightness = -0.285;
static const double kHeliumContrast   = 1000.0;

/// CoreImage 的 Rec.709 亮度权重（`CIColorControls` 的 saturation = 0 走的就是它）。
static const double kHeliumLumaR = 0.2126;
static const double kHeliumLumaG = 0.7152;
static const double kHeliumLumaB = 0.0722;

@implementation AnyBackdropView

@synthesize blurRadius = _blurRadius;
@synthesize compressedFilters = _compressedFilters;

+ (Class)layerClass {
    return [NSClassFromString(@"CABackdropLayer") class];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    [self _installDefaultSettings];
    return self;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    [self _installDefaultSettings];
    return self;
}

- (void)_installDefaultSettings {
    _blurRadius = kHeliumDefaultBlurRadius;
    _compressedFilters = NO;
    [self _updateFilters];
}

#pragma mark - Settings

- (void)setBlurRadius:(CGFloat)blurRadius {
    CGFloat clamped = blurRadius < 0.0 ? 0.0 : (blurRadius > 200.0 ? 200.0 : blurRadius);
    if (_blurRadius == clamped)
        return;   // 设置界面每次改动都会把这一份推过来，值没变就别重建滤镜链
    _blurRadius = clamped;
    [self _updateFilters];
}

- (void)setCompressedFilters:(BOOL)compressedFilters {
    if (_compressedFilters == compressedFilters)
        return;
    _compressedFilters = compressedFilters;
    [self _updateFilters];
}

- (void)_updateFilters {
    // code from Lessica/TrollSpeed
    CAFilter *blurFilter = [CAFilter filterWithName:kCAFilterGaussianBlur];
    [blurFilter setValue:@(self.blurRadius) forKey:@"inputRadius"];
    [blurFilter setValue:@YES forKey:@"inputNormalizeEdges"];  // do not use inputHardEdges

    NSMutableArray<CAFilter *> *filters = [NSMutableArray arrayWithCapacity:5];
    [filters addObject:blurFilter];
    [filters addObjectsFromArray:[self _colorFilters]];
    [self.layer setFilters:filters];
}

/// 颜色链 —— **文字可读性的来源**，模糊半径不参与这件事。
///
/// 上游的 4 趟（数组顺序即施加顺序，每趟之间 CA 会把值 clamp 到 [0, 1]）：
///
///   1. 亮度 −0.285      x → x − 0.285
///   2. 对比度 1000×     x → (x − 0.5)·1000 + 0.5
///   3. 去饱和 0         x → 亮度(x) = 0.2126R + 0.7152G + 0.0722B
///   4. 反相             x → 1 − x
///
/// 1、2 都是仿射，合并成 `x → 1000x − 784.5` —— 阈值正好落在 x = 0.785，也就是
/// 「比 78.5% 亮的背景给黑字，其余给白字」。再与 3、4 合并（亮度权重之和为 1，所以
/// 常数项不会被 3 放大），整条链就是**一个仿射映射**：
///
///   输出 = 785.5 − 1000·(0.2126R + 0.7152G + 0.0722B)      （三通道同值 ⇒ 灰度）
///
/// 用 `kCAFilterColorMatrix` 的 4×5 矩阵表达就是下面那个 `CAColorMatrix`。
///
/// **与 4 趟版本的唯一差别**：折叠之后 1、2 之间那次 clamp 没有了，于是 3 拿到的
/// 不再是「已经二值化的三通道」，而是「同一个大数」。结果是输出从 8 级灰
/// （三通道各自 0/1，亮度只有 2³ 种取值）变成纯黑白两档 —— 反差更大、层次更少。
/// 这正是这一版要拿去真机对比的东西；不喜欢就把开关关掉，回到 4 趟。
///
/// 省下来的是**每帧**的成本：`CABackdropLayer` 只要底下有东西在动（滚动、视频、
/// 动画）就得重新采样并重新过滤，而滤镜按面积跑 —— 一趟比四趟少 3 个全分辨率 pass。
- (NSArray<CAFilter *> *) _colorFilters {
    if (self.compressedFilters) {
        CAFilter *matrixFilter = [CAFilter filterWithName:kCAFilterColorMatrix];
        // 先问一句 `inputKeys` 再设值：`setValue:forKey:` 碰到不认识的键会抛
        // `NSUnknownKeyException`，而这是常驻的 HUD 守护进程 —— 崩不起。问不到就安静地
        // 退回 4 趟版本（观感与以前完全一致，只是没省下那 3 趟），并留一条日志。
        BOOL canUseMatrix = matrixFilter
            && [matrixFilter.inputKeys containsObject:@"inputColorMatrix"]
            && [NSValue respondsToSelector:@selector(valueWithCAColorMatrix:)];
        if (canUseMatrix) {
            // A = 对比度；B = A·亮度 − A/2 + 1/2（把「亮度然后对比度」写成一个仿射）。
            const double A = kHeliumContrast;
            const double B = A * kHeliumBrightness - A * 0.5 + 0.5;
            const double offset = 1.0 - B;   // 输出 = offset − A·(w·x)
            CAColorMatrix m = {
                -A * kHeliumLumaR, -A * kHeliumLumaG, -A * kHeliumLumaB, 0.0, offset,
                -A * kHeliumLumaR, -A * kHeliumLumaG, -A * kHeliumLumaB, 0.0, offset,
                -A * kHeliumLumaR, -A * kHeliumLumaG, -A * kHeliumLumaB, 0.0, offset,
                 0.0,              0.0,              0.0,              1.0, 0.0,
            };
            [matrixFilter setValue:[NSValue valueWithCAColorMatrix:m] forKey:@"inputColorMatrix"];
            return @[matrixFilter];
        }
        os_log_error(OS_LOG_DEFAULT,
                     "Helium: kCAFilterColorMatrix 不可用（inputKeys=%@），退回 4 趟颜色滤镜",
                     matrixFilter ? matrixFilter.inputKeys : nil);
    }

    CAFilter *brightnessFilter = [CAFilter filterWithName:kCAFilterColorBrightness];
    [brightnessFilter setValue:@(kHeliumBrightness) forKey:@"inputAmount"];  // -28.5%

    CAFilter *contrastFilter = [CAFilter filterWithName:kCAFilterColorContrast];
    [contrastFilter setValue:@(kHeliumContrast) forKey:@"inputAmount"];   // 1000x

    CAFilter *saturateFilter = [CAFilter filterWithName:kCAFilterColorSaturate];
    [saturateFilter setValue:@(0.0) forKey:@"inputAmount"];

    CAFilter *colorInvertFilter = [CAFilter filterWithName:kCAFilterColorInvert];

    return @[brightnessFilter, contrastFilter, saturateFilter, colorInvertFilter];
}

@end
