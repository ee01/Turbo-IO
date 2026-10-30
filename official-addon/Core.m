#import "Core.h"
#import "Profile.h"
#import "memory-sync/MemorySyncStore.h"
#include <math.h>

@implementation TIOIdleExitGate {
    NSUInteger _token;
    NSTimeInterval _deadline;
    BOOL _active, _finished;
}
- (NSUInteger)token {return _token;}
- (NSTimeInterval)deadline {return _deadline;}
- (NSUInteger)beginTurn {_active=YES;_finished=NO;_deadline=0;return ++_token;}
- (void)responseFinishedForToken:(NSUInteger)token {if(_active&&token==_token)_finished=YES;}
- (BOOL)beginWaitingForToken:(NSUInteger)token atTime:(NSTimeInterval)now delay:(NSTimeInterval)delay {
    if(!_active||!_finished||token!=_token||_deadline!=0||!isfinite(now)||now<0||!isfinite(delay)||delay<2||delay>120||!isfinite(now+delay))return NO;
    _deadline=now+delay;return YES;
}
- (BOOL)shouldExitForToken:(NSUInteger)token atTime:(NSTimeInterval)now {return _active&&_finished&&token==_token&&_deadline>0&&isfinite(now)&&now>=_deadline;}
- (void)cancel {++_token;_deadline=0;_active=NO;_finished=NO;}
@end

BOOL TIOIsVoiceExitCommand(NSString *text) {
    if(![text isKindOfClass:NSString.class]||!text.length||text.length>48)return NO;
    NSMutableCharacterSet *trim=[NSCharacterSet.whitespaceAndNewlineCharacterSet mutableCopy];
    [trim addCharactersInString:@"，。！？,.!?、：:"];
    NSString *s=[text stringByTrimmingCharactersInSet:trim];
    if([s hasPrefix:@"小雷小雷"])s=[[s substringFromIndex:4] stringByTrimmingCharactersInSet:trim];
    s=[[s componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
    // Exact utterances only. Never use containsString on task or chat content.
    return [@[@"退下吧",@"退下",@"关闭",@"没事了",@"关闭窗口",@"关闭对话",@"结束对话",@"退出对话",@"不用了",@"就这样吧"] containsObject:s];
}

NSString *TIOAppendDelta(NSString *previous, NSString *current) {
    if (previous.length && ![current hasPrefix:previous]) return nil;
    return [current substringFromIndex:previous.length];
}

BOOL TIOIsEligibleChat(NSString *domain, NSString *intent, NSString *sub, BOOL offline, BOOL hasCommand) {
    return [domain isEqual:@"chat"] && [intent isEqual:@"chat"] &&
        [sub isEqual:@"workflow"] && !offline && !hasCommand;
}

NSURL *TIOValidateEndpoint(NSString *input) {
    NSURLComponents *c = [NSURLComponents componentsWithString:[input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    if (!c || ![c.scheme.lowercaseString isEqual:@"https"] || !c.host.length || c.user || c.password || c.fragment || c.query) return nil;
    if (![c.path hasSuffix:@"/chat/completions"]) return nil;
    return c.URL;
}

NSString *TIOSystemPrompt(NSString *model) {
    return [NSString stringWithFormat:@"用简洁中文回答，内容将显示在智能眼镜上。\n你当前使用的模型名称（客户端配置的模型 ID）是：%@。当用户询问你的模型名称时，请准确说明这个模型 ID。\n结合请求中提供的最近历史对话保持上下文连贯；不要编造未提供的用户身份或聊天历史。\n%@",model,TIOProfilePrompt(TIOProfile())];
}

@implementation TIOConversationHistory {
    NSMutableArray<NSDictionary *> *_messages;
}
- (instancetype)init {if((self=[super init]))_messages=[NSMutableArray array];return self;}
- (NSArray<NSDictionary *> *)snapshot {return [_messages copy];}
- (void)clear {[_messages removeAllObjects];}
- (void)appendQuestion:(NSString *)question answer:(NSString *)answer {
    if(!question.length||!answer.length||question.length>16000||answer.length>64000)return;
    [_messages addObject:@{@"role":@"user",@"content":[question copy]}];
    [_messages addObject:@{@"role":@"assistant",@"content":[answer copy]}];
    if(_messages.count>50)[_messages removeObjectsInRange:NSMakeRange(0,_messages.count-50)];
}
@end

NSDictionary *TIOChatRequest(NSString *model, NSString *question) {
    return TIOChatRequestWithHistory(model,question,@[]);
}

NSDictionary *TIOChatRequestWithHistory(NSString *model, NSString *question, NSArray<NSDictionary *> *history) {
    if (!model.length || model.length > 160 || !question.length || question.length > 16000) return nil;
    if ([model rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    if(history.count>50||history.count%2)return nil;
    NSMutableArray *messages=[NSMutableArray arrayWithObject:@{@"role":@"system",@"content":TIOSystemPrompt(model)}];
    for(NSUInteger i=0;i<history.count;i++){
        id row=history[i];if(![row isKindOfClass:NSDictionary.class])return nil;
        NSString *expected=i%2?@"assistant":@"user";id role=row[@"role"],content=row[@"content"];
        if(![role isEqual:expected]||![content isKindOfClass:NSString.class]||![content length]||[content length]>(i%2?64000:16000))return nil;
        [messages addObject:@{@"role":expected,@"content":[content copy]}];
    }
    [messages addObject:@{@"role":@"user",@"content":[question copy]}];
    return @{@"model":model, @"stream":@YES, @"max_tokens":@1024,
      @"messages":[messages copy]};
}

@interface TIOSSEParser ()
@property(nonatomic) NSMutableData *buffer;
@property(nonatomic) NSMutableString *text;
@property(nonatomic) NSMutableArray<NSString *> *eventLines;
@property(nonatomic) NSUInteger bytes;
@property(nonatomic, readwrite) BOOL done;
@property(nonatomic, readwrite) BOOL failed;
@end
@implementation TIOSSEParser
- (instancetype)init { if ((self=[super init])) { _buffer=[NSMutableData data]; _text=[NSMutableString string]; _eventLines=[NSMutableArray array]; } return self; }
- (NSString *)answer { return [_text copy]; }
- (void)event {
    if (!_eventLines.count) return;
    NSString *payload=[_eventLines componentsJoinedByString:@"\n"]; [_eventLines removeAllObjects];
    if ([payload isEqual:@"[DONE]"]) { _done=YES; return; }
    id obj=[NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![obj isKindOfClass:NSDictionary.class] || obj[@"error"]) { _failed=YES; return; }
    id choices=obj[@"choices"];
    if (![choices isKindOfClass:NSArray.class]) { _failed=YES; return; }
    if (![choices count]) return; // Usage-only event.
    id choice=choices[0]; if (![choice isKindOfClass:NSDictionary.class]) { _failed=YES; return; }
    id delta=choice[@"delta"], content=[delta isKindOfClass:NSDictionary.class]?delta[@"content"]:nil;
    if (content && content!=NSNull.null && ![content isKindOfClass:NSString.class]) { _failed=YES; return; }
    if ([content isKindOfClass:NSString.class]) [_text appendString:content];
    if (_text.length>64000) _failed=YES;
    id reason=choice[@"finish_reason"];
    if (reason && reason!=NSNull.null) {
        if (![reason isKindOfClass:NSString.class] || ![@[@"stop",@"length"] containsObject:reason]) _failed=YES;
        else _done=YES;
    }
}
- (BOOL)append:(NSData *)data {
    if (_failed || _done) return !_failed;
    _bytes+=data.length; if (_bytes>4*1024*1024) { _failed=YES; return NO; }
    [_buffer appendData:data];
    while (!_failed && !_done) {
        const uint8_t *p=_buffer.bytes; NSUInteger n=0;
        while (n<_buffer.length && p[n]!='\n') n++;
        if (n==_buffer.length) { if (n>256*1024) _failed=YES; break; }
        NSData *lineData=[_buffer subdataWithRange:NSMakeRange(0,n)];
        [_buffer replaceBytesInRange:NSMakeRange(0,n+1) withBytes:NULL length:0];
        NSString *line=[[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        if (!line) { _failed=YES; break; }
        if ([line hasSuffix:@"\r"]) line=[line substringToIndex:line.length-1];
        if (!line.length) [self event];
        else if ([line hasPrefix:@"data:"]) { NSString *value=[line substringFromIndex:5]; if ([value hasPrefix:@" "]) value=[value substringFromIndex:1]; [_eventLines addObject:value]; }
    }
    return !_failed;
}
@end

@interface TIOTranscriptArchive ()
@property(nonatomic) NSURL *directory;
@property(nonatomic) TIOMemorySyncStore *store;
@end
@implementation TIOTranscriptArchive
- (instancetype)initWithDirectory:(NSURL *)directory { if ((self=[super init])) _directory=directory; return self; }
- (TIOMemorySyncStore *)open:(NSError **)error {
    if (!_store) _store=[[TIOMemorySyncStore alloc] initWithDirectory:_directory error:error];
    return _store;
}
- (BOOL)recordText:(NSString *)text round:(NSString *)round role:(NSString *)role at:(NSDate *)date error:(NSError **)error {
    TIOMemorySyncStore *store=[self open:error]; if (!store) return NO;
    NSDictionary *result=[store recordText:text round:round role:role at:date generation:0 applyUploadPolicy:NO error:error];
    return [result[@"accepted"] boolValue];
}
- (NSArray<NSDictionary *> *)snapshot:(NSError **)error {
    TIOMemorySyncStore *store=[self open:error]; if (!store) return nil;
    return [store snapshot:error];
}
- (NSArray<NSURL *> *)exportAt:(NSDate *)date error:(NSError **)error {
    NSArray<NSDictionary *> *rows=[self snapshot:error]; if (!rows) return nil;
    if(!rows.count) {if(error)*error=[NSError errorWithDomain:@"TurboIOPrivateArchive" code:2 userInfo:@{NSLocalizedDescriptionKey:@"暂无本扩展保存的最终文字。请先开启旁路保存，再使用官方全天智记；旧历史记录暂未导入。"}];return nil;}
    NSURL *folder=[_directory URLByAppendingPathComponent:[@"exports/" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    if(![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return nil;
    NSMutableString *md=[NSMutableString stringWithString:@"# 全天智记导出\n\n来源：启用私用扩展后旁路保存的官方最终文字。不代表完整历史或逐字准确稿。身份和修订号保留在导出里。\n\n"];
    NSMutableArray *publicRows=[NSMutableArray array];
    for(NSDictionary *row in rows) {
        [publicRows addObject:@{@"id":row[@"id"],@"revision":row[@"revision"],@"sessionId":row[@"sessionId"],@"at":row[@"at"],@"updatedAt":row[@"updatedAt"],@"role":row[@"role"],@"text":row[@"text"]}];
        [md appendFormat:@"## %@ · %@ · rev %@\n\n",row[@"at"],row[@"id"],row[@"revision"]];
        for(NSString *line in [row[@"text"] componentsSeparatedByString:@"\n"]) [md appendFormat:@"> %@\n",line];
        [md appendString:@"\n"];
    }
    NSURL *markdown=[folder URLByAppendingPathComponent:@"全天智记.md"], *json=[folder URLByAppendingPathComponent:@"全天智记.json"];
    NSData *data=[NSJSONSerialization dataWithJSONObject:publicRows options:NSJSONWritingPrettyPrinted error:error];
    if(!data || ![data writeToURL:json options:NSDataWritingAtomic error:error] || ![md writeToURL:markdown atomically:YES encoding:NSUTF8StringEncoding error:error]) return nil;
    for(NSURL *file in @[markdown,json]) [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:file.path error:nil];
    return @[markdown,json];
}
@end
