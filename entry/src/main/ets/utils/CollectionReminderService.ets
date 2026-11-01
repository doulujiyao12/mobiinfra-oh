import { common, Want } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { JSON as ArkJSON, util } from '@kit.ArkTS';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { AppLogger } from './AppLogger';
import { getAppBundleName } from './AppIdentity';
import { WorkflowStorage } from './WorkflowStorage';
import {
  COLLECTION_REMINDER_DETAIL_DAYS,
  CollectionReminderIntent,
  CollectionReminderState,
  collectionReminderAddDays,
  collectionReminderCanClaim,
  collectionReminderContent,
  collectionReminderDayKey,
  collectionReminderNextTime,
  collectionReminderPreviousTime,
  collectionReminderStamp,
  normalizeCollectionReminderState
} from './CollectionReminderPolicy';

export const COLLECTION_REMINDER_REQUEST_KEY: string = 'collectionReminderRequest';
export const COLLECTION_REMINDER_READY_KEY: string = 'collectionReminderWindowReady';
export const COLLECTION_REMINDER_VERSION_KEY: string = 'collectionReminderVersion';
const REMINDER_GROUP: string = 'clawmate.daily.collection';
const REMINDER_ACTION: string = 'clawmate.collect.enabled';
const STATE_KEY: string = 'state';
const NOTIFICATION_ID: number = 21900;
// A user-scheduled collection is a service reminder. CONTENT_INFORMATION defaults to silent LEVEL_MIN.
const REMINDER_SLOT_TYPE: notificationManager.SlotType = notificationManager.SlotType.SERVICE_INFORMATION;
// Force existing registrations to pick up notification request changes after an App upgrade.
const REMINDER_REGISTRATION_VERSION: string = 'service-slot-v2';

interface ReminderServiceError { code?: number; message?: string; }

// Only the system reminder owns the clock. No background timer starts GUI actions.
export class CollectionReminderService {
  private static store: preferences.Preferences | undefined = undefined;
  private static context: common.UIAbilityContext | undefined = undefined;
  private static operations: Promise<void> = Promise.resolve();

  static initialize(context: common.UIAbilityContext): void {
    CollectionReminderService.context = context;
    if (CollectionReminderService.store !== undefined) { return; }
    CollectionReminderService.store = preferences.getPreferencesSync(context, { name: 'collection_reminder' });
    let state = CollectionReminderService.load();
    // Upgrade existing installations using actual daily-log artifacts, rather than a failed task's lastRun.
    if (state.lastCollectedAt === 0) {
      for (let file of WorkflowStorage.listDailyLogFiles(context.filesDir)) {
        let modifiedAt = file.modifiedTime * 1000;
        if (modifiedAt > state.lastCollectedAt && modifiedAt <= Date.now()) { state.lastCollectedAt = modifiedAt; }
      }
    }
    CollectionReminderService.save(state);
  }

  static load(): CollectionReminderState {
    let store = CollectionReminderService.store;
    if (store === undefined) { throw new Error('采集提醒尚未初始化'); }
    let raw = store.getSync(STATE_KEY, '') as string;
    let token = util.generateRandomUUID(true);
    if (raw.length === 0) {
      let state = new CollectionReminderState();
      state.planToken = token;
      return state;
    }
    return normalizeCollectionReminderState(ArkJSON.parse(raw) as CollectionReminderState, token);
  }

  static shouldOfferStartupConsent(): boolean {
    let store = CollectionReminderService.store;
    return store !== undefined && store.getSync('startup_prompted', false) !== true;
  }

  static markStartupConsentPrompted(): void {
    let store = CollectionReminderService.store;
    if (store === undefined) { throw new Error('采集提醒尚未初始化'); }
    store.putSync('startup_prompted', true); store.flushSync();
  }

  private static save(state: CollectionReminderState): void {
    let store = CollectionReminderService.store;
    if (store === undefined) { throw new Error('采集提醒尚未初始化'); }
    store.putSync(STATE_KEY, ArkJSON.stringify(state));
    // A notification replay must remain consumed after process death, before the first HDC action.
    store.flushSync();
    AppStorage.setOrCreate(COLLECTION_REMINDER_VERSION_KEY,
      (AppStorage.get<number>(COLLECTION_REMINDER_VERSION_KEY) || 0) + 1);
  }

  private static async serialize(operation: () => Promise<void>): Promise<void> {
    let pending = CollectionReminderService.operations.then(operation);
    CollectionReminderService.operations = pending.catch((): void => {});
    await pending;
  }

  static async refresh(): Promise<void> {
    await CollectionReminderService.serialize(async (): Promise<void> => {
      try { await CollectionReminderService.reconcile(); }
      catch (e) { CollectionReminderService.recordError(e as Error); }
    });
  }

  static async setEnabled(enabled: boolean): Promise<void> {
    await CollectionReminderService.serialize(async (): Promise<void> => {
      CollectionReminderService.markStartupConsentPrompted();
      let state = CollectionReminderService.load();
      state.enabled = enabled;
      state.planToken = util.generateRandomUUID(true);
      state.registeredStamp = '';
      state.errorText = '';
      CollectionReminderService.save(state);
      AppStorage.setOrCreate(COLLECTION_REMINDER_REQUEST_KEY, '');
      try {
        if (enabled) {
          let context = CollectionReminderService.context;
          if (context === undefined) { throw new Error('采集提醒缺少应用上下文'); }
          if (!await notificationManager.isNotificationEnabled()) {
            await notificationManager.requestEnableNotification(context);
          }
          if (!await notificationManager.isNotificationEnabled()) {
            throw new Error('通知未授权，请在系统设置中允许 ClawMate 发送通知');
          }
        }
        await CollectionReminderService.reconcile();
      } catch (e) {
        // Do not leave a newly enabled switch looking effective after registration failed.
        state = CollectionReminderService.load();
        state.enabled = false;
        CollectionReminderService.save(state);
        CollectionReminderService.recordError(e as Error);
        throw e as Error;
      }
    });
  }

  static async setTime(hour: number, minute: number): Promise<void> {
    if (!Number.isInteger(hour) || hour < 0 || hour > 23 ||
      !Number.isInteger(minute) || minute < 0 || minute > 59) { throw new Error('提醒时间无效'); }
    await CollectionReminderService.serialize(async (): Promise<void> => {
      let state = CollectionReminderService.load();
      if (state.hour === hour && state.minute === minute) { return; }
      state.hour = hour;
      state.minute = minute;
      state.planToken = util.generateRandomUUID(true);
      state.registeredStamp = '';
      state.errorText = '';
      CollectionReminderService.save(state);
      AppStorage.setOrCreate(COLLECTION_REMINDER_REQUEST_KEY, '');
      try { await CollectionReminderService.reconcile(); }
      catch (e) { CollectionReminderService.recordError(e as Error); throw e as Error; }
    });
  }

  static async recordSuccessfulCollection(): Promise<void> {
    await CollectionReminderService.serialize(async (): Promise<void> => {
      let state = CollectionReminderService.load();
      state.lastCollectedAt = Date.now();
      state.registeredStamp = '';
      CollectionReminderService.save(state);
      AppLogger.info('CollectionReminder', 'COLLECTION_SUCCESS date=' + collectionReminderDayKey(state.lastCollectedAt));
      try { await CollectionReminderService.reconcile(); }
      catch (e) { CollectionReminderService.recordError(e as Error); }
    });
  }

  private static async reconcile(): Promise<void> {
    let state = CollectionReminderService.load();
    if (!state.enabled && state.reminderIds.length === 0) { return; }
    let valid: reminderAgentManager.ReminderInfo[] = await reminderAgentManager.getAllValidReminders();
    let owned = valid.filter((item: reminderAgentManager.ReminderInfo): boolean =>
      item.reminderReq.groupId !== undefined && item.reminderReq.groupId.startsWith(REMINDER_GROUP + '.'));
    AppLogger.info('CollectionReminder', 'REMINDER_RECONCILE enabled=' + state.enabled +
      ' savedIds=' + state.reminderIds.join(',') + ' systemIds=' +
      owned.map((item: reminderAgentManager.ReminderInfo): number => item.reminderId).join(','));
    let stamp = collectionReminderStamp(state, Date.now()) + ':' + REMINDER_REGISTRATION_VERSION;
    if (state.enabled) {
      if (!await notificationManager.isNotificationEnabled()) {
        throw new Error('通知未授权，请在系统设置中允许 ClawMate 发送通知');
      }
      await notificationManager.addSlot(REMINDER_SLOT_TYPE);
      let slot = await notificationManager.getSlot(REMINDER_SLOT_TYPE);
      AppLogger.info('CollectionReminder', 'REMINDER_CHANNEL type=SERVICE_INFORMATION enabled=' +
        String(slot.enabled) + ' level=' + String(slot.notificationLevel === undefined ? slot.level : slot.notificationLevel));
      if (slot.enabled === false) {
        throw new Error('请在系统设置中打开 ClawMate 的“服务提醒”通知');
      }
    }
    if (state.enabled && state.registeredStamp === stamp && state.reminderIds.length > 0 &&
      state.reminderIds.every((id: number): boolean => owned.some(
        (item: reminderAgentManager.ReminderInfo): boolean => item.reminderId === id))) { return; }
    // Discover our own group after crashes between publishReminder and persistence. Never cancelAllReminders.
    let oldIds = state.reminderIds.slice();
    for (let item of owned) {
      if (oldIds.indexOf(item.reminderId) < 0) { oldIds.push(item.reminderId); }
    }
    let remaining: number[] = [];
    for (let id of oldIds) {
      try { await reminderAgentManager.cancelReminder(id); }
      catch (e) {
        let error = e as ReminderServiceError;
        if (error.code !== 1700003) { remaining.push(id); }
      }
    }
    state = CollectionReminderService.load();
    state.reminderIds = remaining;
    state.registeredStamp = '';
    CollectionReminderService.save(state);
    if (remaining.length > 0) { throw new Error('旧采集提醒取消失败，请稍后重试，尚未创建新提醒'); }
    if (!state.enabled) { AppLogger.info('CollectionReminder', 'REMINDER_DISABLED'); return; }
    let nextTime = collectionReminderNextTime(state.hour, state.minute, Date.now());
    AppLogger.info('CollectionReminder', 'REMINDER_PUBLISH_BEGIN now=' + new Date().toString() +
      ' next=' + new Date(nextTime).toString() + ' slot=SERVICE_INFORMATION');
    let newIds: number[] = [];
    try {
      // Precise date-specific text for the next two weeks. The daily recurring fallback never goes silent.
      for (let day = 0; day < COLLECTION_REMINDER_DETAIL_DAYS; day++) {
        let dueAt = collectionReminderAddDays(nextTime, day);
        let id = await reminderAgentManager.publishReminder(CollectionReminderService.buildRequest(state, dueAt, false));
        newIds.push(id);
        CollectionReminderService.persistPublishedIds(newIds);
        AppLogger.info('CollectionReminder', 'REMINDER_PUBLISHED id=' + id + ' due=' + new Date(dueAt).toString());
      }
      let fallbackAt = collectionReminderAddDays(nextTime, COLLECTION_REMINDER_DETAIL_DAYS);
      let fallbackId = await reminderAgentManager.publishReminder(CollectionReminderService.buildRequest(state, fallbackAt, true));
      newIds.push(fallbackId);
      AppLogger.info('CollectionReminder', 'REMINDER_PUBLISHED id=' + fallbackId + ' recurring=true firstDue=' +
        new Date(fallbackAt).toString());
      // Publishing returning an ID is not enough: confirm that future occurrences remain in the system.
      // An occurrence that fell due during registration may already have expired legitimately.
      let registered = await reminderAgentManager.getAllValidReminders();
      let checkedAt = Date.now();
      let missing = newIds.filter((id: number, index: number): boolean =>
        collectionReminderAddDays(nextTime, index) > checkedAt &&
        !registered.some((item: reminderAgentManager.ReminderInfo): boolean => item.reminderId === id));
      AppLogger.info('CollectionReminder', 'REMINDER_VERIFIED published=' + newIds.length +
        ' retained=' + registered.filter((item: reminderAgentManager.ReminderInfo): boolean =>
          newIds.indexOf(item.reminderId) >= 0).length + ' missingFutureIds=' + missing.join(','));
      if (missing.length > 0) {
        throw new Error('系统未保留 ' + missing.length + ' 条待触发采集提醒，请点击重试并查看调试日志');
      }
      state = CollectionReminderService.load();
      state.reminderIds = newIds;
      state.registeredStamp = stamp;
      state.errorText = '';
      CollectionReminderService.save(state);
      AppLogger.info('CollectionReminder', 'REMINDER_REGISTERED count=' + newIds.length + ' next=' +
        collectionReminderDayKey(nextTime) + ' time=' + state.hour + ':' + state.minute);
    } catch (e) {
      let uncancelled: number[] = [];
      for (let id of newIds) {
        try { await reminderAgentManager.cancelReminder(id); }
        catch (cancelError) { uncancelled.push(id); }
      }
      CollectionReminderService.persistPublishedIds(uncancelled);
      throw e as Error;
    }
  }

  private static persistPublishedIds(ids: number[]): void {
    let state = CollectionReminderService.load();
    state.reminderIds = ids.slice();
    CollectionReminderService.save(state);
  }

  private static buildRequest(state: CollectionReminderState, dueAt: number,
    recurring: boolean): reminderAgentManager.ReminderRequestCalendar {
    let date = new Date(dueAt);
    let request: reminderAgentManager.ReminderRequestCalendar = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
      dateTime: {
        year: date.getFullYear(), month: date.getMonth() + 1, day: date.getDate(),
        hour: date.getHours(), minute: date.getMinutes(), second: 0
      },
      title: '该采集今天的足迹啦',
      content: collectionReminderContent(state.lastCollectedAt, dueAt, !recurring),
      expiredContent: '点此打开 ClawMate，执行已开启的采集任务。',
      notificationId: NOTIFICATION_ID,
      // Closing a grouped reminder can cancel the whole group: each occurrence owns a separate group.
      groupId: REMINDER_GROUP + '.' + (recurring ? 'daily' : collectionReminderDayKey(dueAt)),
      slotType: REMINDER_SLOT_TYPE,
      ringDuration: 1,
      snoozeTimes: 0,
      tapDismissed: true,
      wantAgent: {
        pkgName: getAppBundleName(), abilityName: 'EntryAbility',
        parameters: { collectionReminderAction: REMINDER_ACTION, collectionReminderToken: state.planToken,
          collectionReminderDueAt: recurring ? 0 : dueAt }
      }
    };
    if (deviceInfo.sdkApiVersion >= 23) { request.ringChannel = reminderAgentManager.RingChannel.RING_CHANNEL_NOTIFICATION; }
    if (recurring) { request.daysOfWeek = [1, 2, 3, 4, 5, 6, 7]; }
    return request;
  }

  // EntryAbility is exported: an arbitrary external Want must never trigger GUI collection.
  static enqueueWant(want: Want): void {
    if (want.parameters === undefined || want.parameters['collectionReminderAction'] !== REMINDER_ACTION) { return; }
    let state = CollectionReminderService.load();
    let token = want.parameters['collectionReminderToken'];
    let dueAt = want.parameters['collectionReminderDueAt'];
    if (typeof token !== 'string' || typeof dueAt !== 'number') { return; }
    let intent = new CollectionReminderIntent();
    intent.planToken = token;
    intent.dueAt = dueAt === 0 ? collectionReminderPreviousTime(state.hour, state.minute, Date.now()) : dueAt;
    if (!collectionReminderCanClaim(state, intent, Date.now())) {
      AppLogger.info('CollectionReminder', 'REMINDER_TAP_IGNORED expired/disabled/invalid/already-started');
      return;
    }
    AppLogger.info('CollectionReminder', 'REMINDER_TAPPED date=' + collectionReminderDayKey(intent.dueAt));
    AppStorage.setOrCreate(COLLECTION_REMINDER_REQUEST_KEY, ArkJSON.stringify(intent));
  }

  static pendingIntent(request: string): CollectionReminderIntent | null {
    if (request.length === 0) { return null; }
    try {
      let intent = ArkJSON.parse(request) as CollectionReminderIntent;
      return collectionReminderCanClaim(CollectionReminderService.load(), intent, Date.now()) ? intent : null;
    } catch (e) { return null; }
  }

  static claim(request: string): boolean {
    if (AppStorage.get<string>(COLLECTION_REMINDER_REQUEST_KEY) !== request) { return false; }
    let intent = CollectionReminderService.pendingIntent(request);
    if (intent === null) { return false; }
    let state = CollectionReminderService.load();
    state.handledDays = state.handledDays.concat([collectionReminderDayKey(intent.dueAt)]).slice(-90);
    CollectionReminderService.save(state);
    CollectionReminderService.clearRequest(request);
    AppLogger.info('CollectionReminder', 'REMINDER_BATCH_CLAIMED date=' + collectionReminderDayKey(intent.dueAt));
    return true;
  }

  static clearRequest(request: string): void {
    if (AppStorage.get<string>(COLLECTION_REMINDER_REQUEST_KEY) === request) {
      AppStorage.setOrCreate(COLLECTION_REMINDER_REQUEST_KEY, '');
    }
  }

  private static recordError(error: Error): void {
    let cause = error as ReminderServiceError;
    let state = CollectionReminderService.load();
    state.registeredStamp = '';
    if (cause.code === 201) {
      state.errorText = '提醒未生效：请在 AGC 申请并开通“代理提醒”，更新签名 Profile 后重试。';
    } else if (cause.code === 1700001 || cause.code === 1600004) {
      state.errorText = '提醒未生效：请在系统设置中允许 ClawMate 发送通知后重试。';
    } else if (cause.code === 1700002) {
      state.errorText = '提醒未生效：系统提醒数量已达上限，请稍后重试。';
    } else { state.errorText = '提醒未生效：' + error.message; }
    CollectionReminderService.save(state);
    AppLogger.error('CollectionReminder', 'REMINDER_ERROR code=' + String(cause.code) +
      ' message=' + (cause.message || error.message));
  }
}
