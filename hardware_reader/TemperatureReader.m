//
//  TemperatureReader.m
//  MenuMeters
//
//  Created by Yuji on 1/31/21.
//

#import "TemperatureReader.h"
#if TARGET_CPU_X86_64
#import "smc_reader.h"
#elif TARGET_CPU_ARM64
#import "applesilicon_hardware_reader.h"
#endif

@implementation TemperatureReader
+(NSArray*)sensorNames
{
    static dispatch_once_t once;
    static NSArray*sensorNames;
    dispatch_once(&once, ^{
#if TARGET_CPU_X86_64
    if (kIOReturnSuccess == SMCOpen()) {
        UInt32 count;
        NSMutableArray*a=[NSMutableArray array];
        SMCReadKeysCount(&count);
        for(int i=0;i<count;i++){
            SMCKeyValue val;
            SMCReadKeyAtIndex(i, &val);
            SMCCode key=val.key;
            char s[5]={key.code[3],key.code[2],key.code[1],key.code[0],0};
            NSString*name=[NSString stringWithUTF8String:s];
            if([name hasPrefix:@"T"]&&val.info.dataType.type ==SMC_DATATYPE_SP78.type){
                [a addObject:name];
            }
        }
        SMCClose();
        sensorNames=a;
    }else{
        sensorNames=nil;
    }
#elif TARGET_CPU_ARM64
    sensorNames=[AppleSiliconTemperatureSensorNames() sortedArrayUsingSelector:@selector(compare:)];
#endif
    });
    return sensorNames;
}
+(NSString*)defaultSensor
{
    // Was a plain `if(!foo)` lazy init. The reporter calls this from its work
    // queue while the CPU extra and the prefs pane call it on the main thread, and
    // two threads racing on a __strong static can both assign it, which under ARC
    // releases one of the two values twice.
    static NSString*foo=nil;
    static dispatch_once_t defaultSensorOnce;
    dispatch_once(&defaultSensorOnce,^{
        foo=[self defaultSensorRealWork];
    });
    return foo;
}
+(NSString*)defaultSensorRealWork
{
    NSString* candidate=
#if TARGET_CPU_X86_64
    @"TC0P";
#elif TARGET_CPU_ARM64
    @"SOC MTR Temp Sensor0";
#endif
    if(![self sensorNames])
        return candidate;
    if([[self sensorNames] containsObject:candidate])
        return candidate;
    for(NSString*sensor in [self sensorNames]){
        if([sensor hasPrefix:@"TC"])
            return sensor;
    }
    // sensorNames can be non-nil but empty (no matching sensors), in which case
    // indexing [0] raises NSRangeException.
    if([[self sensorNames] count]==0)
        return candidate;
    return [self sensorNames][0];
}
+(NSString*)displayNameForSensor:(NSString*)name
{
#if TARGET_CPU_X86_64
    // Same race as defaultSensor, but worse: a second thread could previously see
    // the dictionary after it was assigned but before it was filled, and get nil
    // for a sensor that does have a name.
    static NSMutableDictionary*dict=nil;
    static dispatch_once_t displayNameOnce;
    dispatch_once(&displayNameOnce,^{
        NSMutableDictionary*built=[NSMutableDictionary dictionary];
        NSDictionary*rawDict=SMCHumanReadableDescriptions();
        for(NSString*key in [self sensorNames]){
            NSString*s=rawDict[key];
            if(s){
                s=[s stringByReplacingOccurrencesOfString:@"(DegC)" withString:@""];
                s=[s stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"(%@)",key] withString:@""];
                built[key]=[NSString stringWithFormat:@"%@: %@",key,s];
            }else{
                built[key]=key;
            }
        }
        // Published only once fully populated.
        dict=built;
    });
    return dict[name];
#elif TARGET_CPU_ARM64
    return name;
#endif
}
+(float)temperatureOfSensorWithName:(NSString*)name
{
#if TARGET_CPU_X86_64
    float_t celsius = -273.15F;
    if (kIOReturnSuccess == SMCOpen()) {
        SMCKeyValue value;
        //use harcoded value for a while
        //TODO: implement SMC tab to allow setup smc gauges in toolbar
        if (kIOReturnSuccess == SMCReadKey(toSMCCode([name UTF8String]), &value)) {
            celsius = SP78_TO_CELSIUS(value.bytes);
        }
        SMCClose();
    }
    return celsius;
#elif TARGET_CPU_ARM64
	return AppleSiliconTemperatureForName(name);
#endif
}
@end


