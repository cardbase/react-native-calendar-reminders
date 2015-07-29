#import "RNCalendarReminders.h"
#import "RCTConvert.h"
#import <EventKit/EventKit.h>

@interface RNCalendarReminders ()

@property (nonatomic, strong) EKEventStore *eventStore;
@property (copy, nonatomic) NSArray *reminders;
@property (nonatomic) BOOL isAccessToEventStoreGranted;

@end

@implementation RNCalendarReminders

@synthesize bridge = _bridge;

RCT_EXPORT_MODULE()

#pragma mark -
#pragma mark Event Store Initialize

- (EKEventStore *)eventStore
{
    if (!_eventStore) {
        _eventStore = [[EKEventStore alloc] init];
    }
    return _eventStore;
}

- (NSArray *)reminders
{
    if (!_reminders) {
        _reminders = [[NSArray alloc] init];
    }
    return _reminders;
}

#pragma mark -
#pragma mark Event Store Authorization

- (void)authorizationStatusForAccessEventStore
{
    EKAuthorizationStatus status = [EKEventStore authorizationStatusForEntityType:EKEntityTypeReminder];
    
    switch (status) {
        case EKAuthorizationStatusDenied:
        case EKAuthorizationStatusRestricted: {
            self.isAccessToEventStoreGranted = NO;
            break;
        }
        case EKAuthorizationStatusAuthorized:
            self.isAccessToEventStoreGranted = YES;
            [self addNotificationCenter];
            break;
        case EKAuthorizationStatusNotDetermined: {
            [self requestCalendarAccess];
            break;
        }
    }
}

-(void)requestCalendarAccess
{
    __weak RNCalendarReminders *weakSelf = self;
    [self.eventStore requestAccessToEntityType:EKEntityTypeReminder completion:^(BOOL granted, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.isAccessToEventStoreGranted = granted;
            [weakSelf addNotificationCenter];
        });
    }];
}

#pragma mark -
#pragma mark Event Store Accessors

- (void)addReminder:(NSString *)title
          startDate:(NSDateComponents *)startDate
           location:(NSString *)location
{
    if (!self.isAccessToEventStoreGranted) {
        return;
    }
    
    EKReminder *reminder = [EKReminder reminderWithEventStore:self.eventStore];
    reminder.title = title;
    reminder.location = location;
    reminder.dueDateComponents = startDate;
    reminder.calendar = [self.eventStore defaultCalendarForNewReminders];
    
    NSError *error = nil;
    BOOL success = [self.eventStore saveReminder:reminder commit:YES error:&error];
    
    if (!success) {
        [self.bridge.eventDispatcher sendAppEventWithName:@"EventReminderError"
                                                     body:@{@"error": @"Error saving reminder"}];
    }
}

- (void)editReminder:(EKReminder *)reminder
               title:(NSString *)title
           startDate:(NSDateComponents *)startDate
            location:(NSString *)location
{
    if (!self.isAccessToEventStoreGranted) {
        return;
    }
    
    reminder.title = title;
    reminder.location = location;
    reminder.startDateComponents = startDate;
    
    NSError *error = nil;
    BOOL success = [self.eventStore saveReminder:reminder commit:YES error:&error];
    
    if (!success) {
        [self.bridge.eventDispatcher sendAppEventWithName:@"EventReminderError"
                                                     body:@{@"error": @"Error saving reminder"}];
    }
}

- (void)deleteReminder:(NSString *)eventId
{
    if (!self.isAccessToEventStoreGranted) {
        return;
    }
    
    EKReminder *reminder = (EKReminder *)[self.eventStore calendarItemWithIdentifier:eventId];

    NSError *error = nil;
    BOOL success = [self.eventStore removeReminder:reminder commit:NO error:&error];
    
    if (!success) {
        [self.bridge.eventDispatcher sendAppEventWithName:@"EventReminderError"
                                                     body:@{@"error": @"Error removing reminder"}];
    }
    
}

- (NSArray *)serializeReminders:(NSArray *)reminders
{
    NSMutableArray *serializedReminders = [[NSMutableArray alloc] init];
    
    static NSString *const id = @"id";
    static NSString *const title = @"title";
    static NSString *const location = @"location";
    static NSString *const startDate = @"startDate";
    static NSString *const dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z";
    
    NSDictionary *empty_reminder = @{
        title: @"",
        location: @"",
        startDate: @""
    };
    
    for (EKReminder *reminder in reminders) {
        
        NSMutableDictionary *formedReminder = [NSMutableDictionary dictionaryWithDictionary:empty_reminder];

        if (reminder.calendarItemIdentifier) {
            [formedReminder setValue:reminder.calendarItemIdentifier forKey:id];
        }

        if (reminder.title) {
            [formedReminder setValue:reminder.title forKey:title];
        }

        if (reminder.location) {
            [formedReminder setValue:reminder.location forKey:location];
        }
        
        if (reminder.startDateComponents) {
            NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
            NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
            
            NSLocale *enUSPOSIXLocale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            NSTimeZone *timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
            
            [dateFormatter setTimeZone:timeZone];
            [dateFormatter setLocale:enUSPOSIXLocale];
            [dateFormatter setDateFormat:dateFormat];
            
            NSDate *reminderStartDate = [calendar dateFromComponents:reminder.startDateComponents];
            
            [formedReminder setValue:[dateFormatter stringFromDate:reminderStartDate] forKey:startDate];
        }
        
        [serializedReminders addObject:formedReminder];
    }
    
    NSArray *remindersCopy = [serializedReminders copy];
    
    return remindersCopy;
}

#pragma mark -
#pragma mark notifications

- (void)addNotificationCenter
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(calendarEventReminderReceived:)
                                                 name:EKEventStoreChangedNotification
                                               object:nil];
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)calendarEventReminderReceived:(NSNotification *)notification
{
    NSPredicate *predicate = [self.eventStore predicateForRemindersInCalendars:nil];
    
    __weak RNCalendarReminders *weakSelf = self;
    [self.eventStore fetchRemindersMatchingPredicate:predicate completion:^(NSArray *reminders) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.bridge.eventDispatcher sendAppEventWithName:@"EventReminder"
                                                             body:[weakSelf serializeReminders:reminders]];
        });
    }];
    
}

#pragma mark -
#pragma mark RCT Exports

RCT_EXPORT_METHOD(authorizeEventStore:(RCTResponseSenderBlock)callback)
{
    [self authorizationStatusForAccessEventStore];
    callback(@[@(self.isAccessToEventStoreGranted)]);
}

RCT_EXPORT_METHOD(fetchAllReminders:(RCTResponseSenderBlock)callback)
{
    NSPredicate *predicate = [self.eventStore predicateForRemindersInCalendars:nil];
    
    __weak RNCalendarReminders *weakSelf = self;
    [self.eventStore fetchRemindersMatchingPredicate:predicate completion:^(NSArray *reminders) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.reminders = reminders;
            callback(@[[weakSelf serializeReminders:reminders]]);
        });
    }];
}

RCT_EXPORT_METHOD(saveReminder:(NSString *)title details:(NSDictionary *)details)
{
    NSString *eventId = [RCTConvert NSString:details[@"eventId"]];
    NSString *location = [RCTConvert NSString:details[@"location"]];
    NSDate *startDate = [RCTConvert NSDate:details[@"startDate"]];
    
    NSCalendar *gregorianCalendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
    NSDateComponents *startDateComponents = [gregorianCalendar components:(NSCalendarUnitEra | NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay)
                                                                 fromDate:startDate];

    if (eventId) {
        EKReminder *reminder = (EKReminder *)[self.eventStore calendarItemWithIdentifier:eventId];
        [self editReminder:reminder title:title startDate:startDateComponents location:location];
    
    } else {
        [self addReminder:title startDate:startDateComponents location:location];
    }
}

RCT_EXPORT_METHOD(removeReminder:(NSString *)eventId)
{
    [self deleteReminder:(NSString *)eventId];
}

@end
