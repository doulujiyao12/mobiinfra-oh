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
    let stamp = collectionReminderStamp(state, Date.now());
    if (state.enabled && !await notificationManager.isNotificationEnabled()) {
      throw new Error('通知未授权，请在系统设置中允许 ClawMate 发送通知');
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
    await notificationManager.addSlot(notificationManager.SlotType.CONTENT_INFORMATION);
    let nextTime = collectionReminderNextTime(state.hour, state.minute, Date.now());
    let newIds: number[] = [];
    try {
      // Precise date-specific text for the next two weeks. The daily recurring fallback never goes silent.
      for (let day = 0; day < COLLECTION_REMINDER_DETAIL_DAYS; day++) {
        let dueAt = collectionReminderAddDays(nextTime, day);
        let id = await reminderAgentManager.publishReminder(CollectionReminderService.buildRequest(state, dueAt, false));
        newIds.push(id);
        CollectionReminderService.persistPublishedIds(newIds);
      }
      let fallbackAt = collectionReminderAddDays(nextTime, COLLECTION_REMINDER_DETAIL_DAYS);
      newIds.push(await reminderAgentManager.publishReminder(CollectionReminderService.buildRequest(state, fallbackAt, true)));
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
      slotType: notificationManager.SlotType.CONTENT_INFORMATION,
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
    AppLogger.errorCause('CollectionReminder', 'REMINDER_ERROR', error);
  }
}
