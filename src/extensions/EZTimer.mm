//
//  EZTimer.mm
//  EZKit
//
//  Created by macbook pro on 2018/3/20.
//  Copyright © 2018年 sheep. All rights reserved.
//

#import "EZTimer.h"

#define EZTimerQueueName(x) [NSString stringWithFormat:@"NSTimer_%@_queue",x]

#define EZTimerDfaultLeeway 0.1

#define EZTimerDfaultTimeInterval 60

#define EZTIMERSTATUSKEY_RESUME @"EZTIMERSTATUSKEY_RESUME"
#define EZTIMERSTATUSKEY_PAUSE  @"EZTIMERSTATUSKEY_PAUSE"

// #ifdef DEBUG
//     #define EZLog(...) NSLog(__VA_ARGS__)
// #else
    #define EZLog(...)
// #endif

@interface EZTimer()

@property(nonatomic,strong)NSMutableDictionary *timers;

@property(nonatomic,strong)NSMutableDictionary *timersFlags;

@end

@implementation EZTimer

+(instancetype)shareInstance{
    static EZTimer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[EZTimer alloc] init];
    });
    
    return instance;
}


-(void)repeatTimer:(NSString*)timerName timerInterval:(double)interval resumeType:(EZTimerResumeType)resumeType action:(EZTimerBlock)action{
    [self timer:timerName timerInterval:interval leeway:EZTimerDfaultLeeway resumeType:resumeType queue:EZTimerQueueTypeGlobal queueName:nil repeats:YES action:action];
}


-(void)timer:(NSString*)timerName timerInterval:(double)interval leeway:(double)leeway resumeType:(EZTimerResumeType)resumeType queue:(EZTimerQueueType)queue queueName:(NSString *)queueName repeats:(BOOL)repeats action:(EZTimerBlock)action{
    
    dispatch_queue_t que = nil;
    if (!timerName) { return; }
    if (!queueName) {
        queueName = EZTimerQueueName(timerName);
    }
    switch (queue) {

        case EZTimerQueueTypeConcurrent:{
            que = dispatch_queue_create([queueName UTF8String], DISPATCH_QUEUE_CONCURRENT);
            break;
        }
        case EZtimerQueueTypeSerial:{
            que = dispatch_queue_create([queueName UTF8String], DISPATCH_QUEUE_SERIAL);
            break;
        }
        default:
            que = dispatch_get_global_queue(0, 0);
            break;
    }
    dispatch_source_t timer = [self.timers objectForKey:timerName];
    if (!timer) {
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, que);
        [self.timers setObject:timer forKey:timerName];
        //timer 状态标识
        NSMutableDictionary *dic =[NSMutableDictionary dictionaryWithObjectsAndKeys:@0,EZTIMERSTATUSKEY_RESUME,@0,EZTIMERSTATUSKEY_PAUSE, nil];
        [self.timersFlags setObject:dic forKey:timerName];
    }
    
    dispatch_source_set_timer(timer, dispatch_walltime(NULL, 0), (interval==0?EZTimerDfaultTimeInterval:interval) * NSEC_PER_SEC, (leeway == 0 ? EZTimerDfaultLeeway:leeway) * NSEC_PER_SEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        EZLog(@"tiemr action");
        action(timerName);
        if (!repeats) {
            //dispatch_source_cancel(timer);
            [weakSelf cancel:timerName];
            EZLog(@"tiemr action once");
        }
    });
    if (resumeType == EZTimerResumeTypeNow) {
        //dispatch_resume(timer);
        [self resume:timerName];
    }else{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)), que, ^{
            //dispatch_resume(timer);
            [weakSelf resume:timerName];
        });
    }
}


//当 timer 处于 suspend状态时不能被 释放.
//
// 修过一处：`dispatch_source_cancel` 原来放在 `if (已挂起)` 里面。那条分支的意思是
// 「挂起的 source 要先 resume 才能释放」，是对的；但它把 cancel 一起关了进来，于是
// **取消一个正在运行的 timer 只是把它从 timers 字典里删掉** —— source 仍在按自己的
// 间隔一直触发，而且字典里的名字没了，再也没人能停掉它。
//
// 症状不是崩溃，是静默的浪费：`HUDRootViewController` 在部件被关掉时调 cancel:，
// 于是那个部件的 `updateLabel:`（含 `formattedAttributedString` 与一次
// `dispatch_sync` 回主队列）**永久每秒跑一次**，画在被隐藏的 label 上。重新打开该部件
// 时又会新建一个 source，于是同一个部件有两份在跑，关掉再打开一次就多一份。
-(void)cancel:(NSString *)timerName{
    
    dispatch_source_t timer = [self.timers objectForKey:timerName];
    //NSAssert(timer, @"%s\n定时器列表中不存在此名称的timer -- %@",__func__,timerName);
    if (!timer) {
        EZLog(@"tiemr cancel retrun - because timer had been cancel");
        return;
    }
    NSMutableDictionary *timerDic = [self.timersFlags objectForKey:timerName];
    if (timerDic && [timerDic[EZTIMERSTATUSKEY_PAUSE] boolValue]) {
        EZLog(@"timer had paused，resume first then cancel it");
        // 挂起的 source 必须先 resume：`dispatch_source_cancel` 只是打个标记，
        // 它要等 source 回到可运行状态才真正释放。
        dispatch_resume(timer);
    }
    dispatch_source_cancel(timer);
    [self.timers removeObjectForKey:timerName];
    [self.timersFlags removeObjectForKey:timerName];
    
    EZLog(@"tiemr cancel - cancel");
    
}

-(void)pause:(NSString *)timerName{

    dispatch_source_t timer = [self.timers objectForKey:timerName];
    //NSAssert(timer, @"%s\n定时器列表中不存在此名称的timer -- %@",__func__,timerName);
    if (!timer) {
        return;
    }
    NSMutableDictionary *timerDic = [self.timersFlags objectForKey:timerName];
    if (timerDic && [timerDic[EZTIMERSTATUSKEY_PAUSE] boolValue]) {
        EZLog(@"tiemr pause return- because timer had paused");
        return ;
    }
    dispatch_suspend(timer);
    timerDic[EZTIMERSTATUSKEY_PAUSE] = @1;
    timerDic[EZTIMERSTATUSKEY_RESUME] = @0;
    EZLog(@"tiemr pause - paused" );
    
}

-(void)resume:(NSString *)timerName{
    dispatch_source_t timer = [self.timers objectForKey:timerName];
    //NSAssert(timer, @"%s\n定时器列表中不存在此名称的timer -- %@",__func__,timerName);
    if (!timer) {
        return;
    }
    NSMutableDictionary *timerDic = [self.timersFlags objectForKey:timerName];
    if (timerDic && [timerDic[EZTIMERSTATUSKEY_RESUME] boolValue]) {
        EZLog(@"timer resuem return - because timer had resume");
        return;
    }
    dispatch_resume(timer);
    timerDic[EZTIMERSTATUSKEY_RESUME] = @1;
    timerDic[EZTIMERSTATUSKEY_PAUSE] = @0;
    EZLog(@"tiemr resume - resumed");

}

-(NSMutableDictionary *)timers{
    if (!_timers) {
        _timers = [NSMutableDictionary dictionary];
    }
    return _timers;
}

-(NSMutableDictionary *)timersFlags{
    if (!_timersFlags) {
        _timersFlags = [NSMutableDictionary dictionary];
    }
    return _timersFlags;
}

@end
