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
        @try {
            CAFilter *matrixFilter = [CAFilter filterWithName:kCAFilterColorMatrix];
            // 可用性检查**只用 `respondsToSelector:`** —— 它对任何对象都安全。
            //
            // 0.27 在这里直接调了 `matrixFilter.inputKeys`，真机（iOS 16.5）上
            // CAFilter 根本不响应这个方法：unrecognized selector → 常驻 HUD 进程
            // abort → 部件全部消失（崩溃日志 Helium-2026-10-09-160003.ips 实锤，
            // 崩点正在这条 stub 上）。而 `setValue:forKey:` 是 CAFilter 自己实现的
            // KVC 入口，0.25 起的 4 趟链一直靠它工作，不经过 `inputKeys`。
            BOOL canUseMatrix = matrixFilter != nil
                && [matrixFilter respondsToSelector:@selector(setValue:forKey:)]
                && [NSValue respondsToSelector:@selector(valueWithCAColorMatrix:)];
            if (canUseMatrix) {
                // `CAColorMatrix` 的字段是 float，而上面那两个参数和亮度权重是 double ——
                // C++11 的聚合初始化**不允许**隐式窄化（-Wc++11-narrowing 在这里是 error），
                // 所以先全部落到 float 上再填。
                // A = 对比度；B = A·亮度 − A/2 + 1/2（把「亮度然后对比度」写成一个仿射）。
                const float A = (float)kHeliumContrast;
                const float wR = (float)kHeliumLumaR;
                const float wG = (float)kHeliumLumaG;
                const float wB = (float)kHeliumLumaB;
                const float B = A * (float)kHeliumBrightness - A * 0.5f + 0.5f;
                const float offset = 1.0f - B;   // 输出 = offset − A·(w·x)
                CAColorMatrix m = {
                    -A * wR, -A * wG, -A * wB, 0.0f, offset,
                    -A * wR, -A * wG, -A * wB, 0.0f, offset,
                    -A * wR, -A * wG, -A * wB, 0.0f, offset,
                     0.0f,    0.0f,    0.0f,    1.0f, 0.0f,
                };
                // `setValue:forKey:` 碰到不认识的键会抛 `NSUnknownKeyException` ——
                // 上面那个 @catch 会接住它并退回 4 趟。常驻进程崩不起，宁可白跑。
                [matrixFilter setValue:[NSValue valueWithCAColorMatrix:m] forKey:@"inputColorMatrix"];
                return @[matrixFilter];
            }
        } @catch (NSException *exception) {
            // 任何一步不符合预期（类不在、方法不响应、键不认识）都安静地退回 4 趟：
            // 观感与 0.26 完全一致，只是没省下那 3 趟 —— 绝不能让 HUD 进程死掉。
            os_log_error(OS_LOG_DEFAULT,
                         "Helium: 压缩滤镜不可用（%@: %@），退回 4 趟颜色滤镜",
                         exception.name, exception.reason);
        }
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
