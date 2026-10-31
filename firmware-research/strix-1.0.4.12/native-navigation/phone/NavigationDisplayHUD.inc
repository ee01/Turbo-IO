// Included inside TIONavigationPanel. Uses the same pinned SDK manager, no second navigation engine.
#if TIO_DISPLAY_PHONE
- (NSDictionary *)displayHUDFrame{
#if TIO_DAILY_NAVIGATION
 NSMutableDictionary *frame=[self.display mutableCopy];frame[@"routeGeneration"]=@(self.generation);frame[@"navObservedAt"]=@(self.lastInfo);return frame;
#else
 return self.display;
#endif
}
- (BOOL)canStartDisplayHUD{
 NSDictionary *t=TIONavTransportStatus();
#if TIO_DAILY_NAVIGATION
 if(![TIONavigationCompatibilityStatus()[@"lensNavigationAllowed"] boolValue])return NO;
#endif
 return self.active&&!self.routeReady&&!self.fixture&&!self.planning&&!self.rerouting&&!self.gpsWeak&&NSProcessInfo.processInfo.systemUptime-self.lastInfo<=15&&[self.display[@"phase"] isEqual:@"navigating"]&&![self.subtitleHUD.status[@"enabled"] boolValue]&&[TIOSubtitleNavigationStatus()[@"phase"] isEqual:@"idle"]&&![self.teleHUD.status[@"enabled"] boolValue]&&![TIONewsTeleStatus()[@"active"] boolValue]&&![t[@"enabled"] boolValue]&&![t[@"pending"] boolValue]&&![t[@"notices"] boolValue]&&![t[@"noticePending"] boolValue];
}
#if TIO_DAILY_NAVIGATION
- (void)buildDisplayHUD{
 UILabel *title=[self navLabel:@"眼镜导航" size:16 weight:UIFontWeightSemibold];[self.lensCard addArrangedSubview:title];
 UILabel *guide=[self navLabel:@"开始导航后自动请求进入镜片导航。眼镜须在首页、未合上且没有语音或其他任务占用。" size:12 weight:UIFontWeightRegular];guide.textColor=UIColor.secondaryLabelColor;[self.lensCard addArrangedSubview:guide];
 self.tdpStatus=[self navLabel:@"等待开始导航" size:12 weight:UIFontWeightRegular];self.tdpStatus.accessibilityIdentifier=@"navigation-tdp-status";[self.lensCard addArrangedSubview:self.tdpStatus];
 self.tdpButton=[self navAction:@"停止眼镜导航" icon:@"stop.circle" selector:@selector(toggleDisplayHUD) primary:NO];self.tdpButton.accessibilityIdentifier=@"navigation-tdp-stop";[self.lensCard addArrangedSubview:self.tdpButton];
}
#else
- (void)buildDisplayHUD{
 UILabel *title=[self navLabel:@"眼镜原生导航 · TNV1" size:16 weight:UIFontWeightSemibold];[self.lensCard addArrangedSubview:title];
 UILabel *guide=[self navLabel:@"① 先刷入TNV1实验固件\n② 规划路线 → 开始模拟或导航\n③ 点开启，手机主动打开眼镜导航页，无需手动进菜单\n内置箭头＋文字＋路线示意图（非地图底图）。默认60秒无有效更新息屏，实体键可唤醒，返回键退出。试验用品，请以手机和道路实际指示为准。" size:12 weight:UIFontWeightRegular];guide.textColor=UIColor.secondaryLabelColor;[self.lensCard addArrangedSubview:guide];
 UIStackView *row=[UIStackView new];UILabel *label=[self navLabel:@"导航常亮（断连仍有超时保护）" size:13 weight:UIFontWeightRegular];UISwitch *toggle=[UISwitch new];toggle.on=TNVAlways();[toggle addTarget:self action:@selector(nativeNavAlwaysChanged:) forControlEvents:UIControlEventValueChanged];[row addArrangedSubview:label];[row addArrangedSubview:toggle];[self.lensCard addArrangedSubview:row];
 self.tdpPreview=[UIImageView new];self.tdpPreview.contentMode=UIViewContentModeScaleAspectFit;self.tdpPreview.backgroundColor=UIColor.blackColor;self.tdpPreview.clipsToBounds=YES;self.tdpPreview.layer.cornerRadius=10;[self.tdpPreview.heightAnchor constraintEqualToAnchor:self.tdpPreview.widthAnchor multiplier:0.25].active=YES;[self.lensCard addArrangedSubview:self.tdpPreview];
 self.tdpStatus=[self navLabel:@"单次最多328字节；不再传整幅导航图片" size:12 weight:UIFontWeightRegular];self.tdpStatus.accessibilityIdentifier=@"navigation-tdp-status";[self.lensCard addArrangedSubview:self.tdpStatus];
 self.tdpButton=[self navAction:@"开启眼镜原生导航" icon:@"arrow.triangle.turn.up.right.diamond" selector:@selector(toggleDisplayHUD) primary:YES];self.tdpButton.accessibilityIdentifier=@"navigation-tdp-enable";[self.lensCard addArrangedSubview:self.tdpButton];
}
#endif
- (void)nativeNavAlwaysChanged:(UISwitch *)sender{TNVSetAlways(sender.on);}
#if TIO_DAILY_NAVIGATION
- (void)refreshDisplayHUD{
 if(!self.tdpStatus)return;NSDictionary *s=TDPPhoneNavigationStatus();BOOL on=[s[@"active"] boolValue];
 self.tdpButton.hidden=!on;self.tdpButton.enabled=on;
#if TIO_DAILY_NAVIGATION
 NSDictionary *compatibility=TIONavigationCompatibilityStatus();
 if(![compatibility[@"lensNavigationAllowed"] boolValue]){self.tdpStatus.text=compatibility[@"reason"];return;}
#endif
 self.tdpStatus.text=s[@"note"]?:@"等待开始导航";
}
- (void)attemptAutomaticDisplayHUD{
 if(!self.nativeAutoStartPending)return;
#if TIO_DAILY_NAVIGATION
 if(![TIONavigationCompatibilityStatus()[@"lensNavigationAllowed"] boolValue]){self.nativeAutoStartPending=NO;[self refreshDisplayHUD];return;}
#endif
 if(![self canStartDisplayHUD])return;
 self.nativeAutoStartPending=NO;
 if(!TDPPhoneNavigationStart([self displayHUDFrame]))self.note=@"手机导航继续；眼镜导航未能启动，请查看连接与占用状态";
 [self refreshDisplayHUD];
}
- (void)toggleDisplayHUD{
 self.nativeAutoStartPending=NO;
 if([TDPPhoneNavigationStatus()[@"active"] boolValue])TDPPhoneNavigationStop();
 [self refreshDisplayHUD];
}
#else
- (void)refreshDisplayHUD{
 if(!self.tdpButton)return;NSDictionary *s=TDPPhoneNavigationStatus();BOOL on=[s[@"active"] boolValue];
 UIButtonConfiguration *c=self.tdpButton.configuration;c.title=on?@"停止并退出眼镜导航":@"开启眼镜原生导航";self.tdpButton.configuration=c;self.tdpButton.enabled=on||[self canStartDisplayHUD];
 self.tdpStatus.text=[NSString stringWithFormat:@"%@\n已确认 %@ 个快照 · %@\n路线示意图，不含路口实景或底图",s[@"note"],s[@"snapshots"]?:@0,TNVAlways()?@"常亮":@"60秒无更新息屏"];
 self.tdpPreview.hidden=YES; // Old pixel renderer is not an accurate TNV1 preview.
}
- (void)toggleDisplayHUD{
 if([TDPPhoneNavigationStatus()[@"active"] boolValue]){TDPPhoneNavigationStop();[self refreshDisplayHUD];return;}
 if(![self canStartDisplayHUD]){[self alert:@"先开始高德导航" message:@"等待转向和距离出现，并先结束字幕、提词、录音及其他眼镜任务。"] ;return;}
 NSUInteger g=self.generation;UIAlertController *a=[UIAlertController alertControllerWithTitle:@"开启原生导航？" message:@"需TNV1专用固件。眼镜在首页即可，收到START后自动进入第九项导航；不要同时运行录音、语音或其他显示任务。本轮请先用模拟路线验收。" preferredStyle:UIAlertControllerStyleAlert];
 [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
 [a addAction:[UIAlertAction actionWithTitle:@"已确认，开始" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){if(g!=self.generation||![self canStartDisplayHUD])return;BOOL ok=TDPPhoneNavigationStart([self displayHUDFrame]);if(!ok)[self alert:@"HUD未开启" message:@"请确认连接和无在途文件，再查看状态；不会自动重试。"] ;[self refreshDisplayHUD];}]];[self presentViewController:a animated:YES completion:nil];
}
- (void)attemptAutomaticDisplayHUD{}
#endif
#if TIO_AMAP_ENABLED
- (void)attachNativeHUD{
 if(self.sessionTransport==TIONavigationRide)return; // Native HUD advertises walk/drive, not ride.
 self.nativeHUD=[[AMapNaviHUDView alloc]initWithFrame:CGRectMake(0,0,320,180)];self.nativeHUD.isLandscape=YES;self.nativeHUD.isMirror=NO;self.nativeHUD.showRemainDistance=YES;self.nativeHUD.showRemainTime=YES;
 [self.nativeHUD.heightAnchor constraintEqualToConstant:180].active=YES;[self.lensCard addArrangedSubview:self.nativeHUD];[self.manager addDataRepresentative:self.nativeHUD];
}
- (void)driveManager:(AMapNaviDriveManager *)m updateTurnIconImage:(UIImage *)image turnIconType:(AMapNaviIconType)type{
 dispatch_async(dispatch_get_main_queue(),^{if((id)m!=self.manager||!self.active||self.rerouting||self.planning)return;self.hudIconPixels=TDPHUDImagePixels(image,NO);self.hudIconType=type;self.iconReceivedCount++;TDPPhoneNavigationOffer([self displayHUDFrame]);[self refreshDisplayHUD];});
}
- (void)driveManager:(AMapNaviDriveManager *)m showCrossImage:(UIImage *)image{
 dispatch_async(dispatch_get_main_queue(),^{if((id)m!=self.manager||!self.active||self.rerouting||self.planning)return;self.crossPixels=TDPHUDImagePixels(image,YES);self.crossReceived=NSProcessInfo.processInfo.systemUptime;self.crossReceivedCount++;TDPPhoneNavigationOffer([self displayHUDFrame]);[self refreshDisplayHUD];});
}
- (void)driveManagerHideCrossImage:(AMapNaviDriveManager *)m{
 dispatch_async(dispatch_get_main_queue(),^{if((id)m!=self.manager)return;self.crossPixels=nil;TDPPhoneNavigationOffer([self displayHUDFrame]);[self refreshDisplayHUD];});
}
#endif
#endif
