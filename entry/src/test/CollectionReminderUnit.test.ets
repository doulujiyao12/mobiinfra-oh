import { describe, expect, it } from '@ohos/hypium';
import {
  COLLECTION_REMINDER_MAX_AGE_MS,
  CollectionReminderIntent,
  CollectionReminderState,
  collectionReminderAddDays,
  collectionReminderCanClaim,
  collectionReminderContent,
  collectionReminderDayKey,
  collectionReminderMissedDays,
  collectionReminderNextTime,
  collectionReminderPreviousTime,
  collectionReminderStamp,
  collectionReminderTimeText,
  normalizeCollectionReminderState
} from '../main/ets/utils/CollectionReminderPolicy';

function localTime(year: number, month: number, day: number, hour: number = 0, minute: number = 0): number {
  return new Date(year, month - 1, day, hour, minute, 0, 0).getTime();
}

function enabledPlan(): CollectionReminderState {
  let state = new CollectionReminderState();
  state.enabled = true;
  state.planToken = 'private-plan';
  return state;
}

function intentFor(dueAt: number): CollectionReminderIntent {
  let intent = new CollectionReminderIntent();
  intent.planToken = 'private-plan';
  intent.dueAt = dueAt;
  return intent;
}

export default function collectionReminderUnitTest(): void {
  describe('CollectionReminderUnitTest', (): void => {
    it('defaultsToNinePmAndWaitsForUserOptIn', 0, (): void => {
      let state = new CollectionReminderState();
      expect(collectionReminderTimeText(state.hour, state.minute)).assertEqual('21:00');
      expect(state.enabled).assertFalse();
    });

    it('choosesTodayBeforeTimeAndTomorrowAtOrAfterTime', 0, (): void => {
      let due = localTime(2026, 10, 14, 21);
      expect(collectionReminderNextTime(21, 0, due - 1)).assertEqual(due);
      expect(collectionReminderNextTime(21, 0, due)).assertEqual(localTime(2026, 10, 15, 21));
      expect(collectionReminderNextTime(21, 0, due + 60000)).assertEqual(localTime(2026, 10, 15, 21));
    });

    it('handlesMonthYearAndLeapDayBoundaries', 0, (): void => {
      expect(collectionReminderDayKey(collectionReminderNextTime(21, 0, localTime(2026, 12, 31, 22))))
        .assertEqual('2027-01-01');
      expect(collectionReminderDayKey(collectionReminderAddDays(localTime(2028, 2, 28, 21), 1)))
        .assertEqual('2028-02-29');
      expect(collectionReminderDayKey(collectionReminderAddDays(localTime(2028, 2, 28, 21), 2)))
        .assertEqual('2028-03-01');
    });

    it('resolvesRecurringNotificationToMostRecentDueTime', 0, (): void => {
      expect(collectionReminderPreviousTime(21, 0, localTime(2026, 10, 15, 8)))
        .assertEqual(localTime(2026, 10, 14, 21));
      expect(collectionReminderPreviousTime(21, 0, localTime(2026, 10, 15, 21)))
        .assertEqual(localTime(2026, 10, 15, 21));
    });

    it('keepsTheNextScheduledReminderAfterAManualCollectionOnTheSameDay', 0, (): void => {
      let state = enabledPlan();
      state.lastCollectedAt = localTime(2026, 10, 15, 20, 58);
      let due = collectionReminderNextTime(state.hour, state.minute, state.lastCollectedAt);
      expect(due).assertEqual(localTime(2026, 10, 15, 21));
      expect(collectionReminderCanClaim(state, intentFor(due), due + 1000)).assertTrue();
      expect(collectionReminderContent(state.lastCollectedAt, due, true)).assertContain('今天已采集过');
    });

    it('countsLocalCalendarDaysRatherThanElapsedHours', 0, (): void => {
      expect(collectionReminderMissedDays(localTime(2026, 10, 14, 23, 59), localTime(2026, 10, 15, 0, 1)))
        .assertEqual(1);
      expect(collectionReminderMissedDays(localTime(2026, 10, 15, 8), localTime(2026, 10, 15, 21)))
        .assertEqual(0);
      expect(collectionReminderMissedDays(localTime(2026, 10, 16), localTime(2026, 10, 15))).assertEqual(0);
      expect(collectionReminderMissedDays(0, localTime(2026, 10, 15))).assertEqual(0);
    });

    it('createsDatedNotificationTextAndHonestLongTermFallback', 0, (): void => {
      let last = localTime(2026, 10, 12, 10);
      expect(collectionReminderContent(last, localTime(2026, 10, 15, 21), true).indexOf('3 天') >= 0).assertTrue();
      let fallback = collectionReminderContent(last, localTime(2026, 11, 15, 21), false);
      expect(fallback.indexOf('2026-10-12') >= 0).assertTrue();
      expect(fallback.indexOf('连续') < 0).assertTrue();
      expect(collectionReminderContent(0, localTime(2026, 10, 15, 21), true).indexOf('首次采集') >= 0).assertTrue();
    });

    it('claimsEachDailyOccurrenceOnlyOnceAcrossRestoredState', 0, (): void => {
      let state = enabledPlan();
      let due = localTime(2026, 10, 14, 21);
      let intent = intentFor(due);
      expect(collectionReminderCanClaim(state, intent, due + 1000)).assertTrue();
      state.handledDays.push(collectionReminderDayKey(due));
      let restored = normalizeCollectionReminderState(state, 'different-fallback');
      expect(collectionReminderCanClaim(restored, intent, due + 2000)).assertFalse();
      let nextDue = localTime(2026, 10, 15, 21);
      expect(collectionReminderCanClaim(restored, intentFor(nextDue), nextDue + 1000)).assertTrue();
    });

    it('rejectsForeignOldDisabledFutureExpiredAndMalformedLaunches', 0, (): void => {
      let state = enabledPlan();
      let due = localTime(2026, 10, 14, 21);
      let intent = intentFor(due);
      expect(collectionReminderCanClaim(state, intent, due - 1)).assertFalse();
      expect(collectionReminderCanClaim(state, intent, due + COLLECTION_REMINDER_MAX_AGE_MS)).assertFalse();
      intent.planToken = 'foreign-plan';
      expect(collectionReminderCanClaim(state, intent, due + 1)).assertFalse();
      intent.planToken = state.planToken;
      state.enabled = false;
      expect(collectionReminderCanClaim(state, intent, due + 1)).assertFalse();
      state.enabled = true;
      state.planToken = 'replacement-plan';
      expect(collectionReminderCanClaim(state, intent, due + 1)).assertFalse();
      intent.planToken = state.planToken;
      intent.dueAt = NaN;
      expect(collectionReminderCanClaim(state, intent, due + 1)).assertFalse();
      intent.dueAt = 0;
      expect(collectionReminderCanClaim(state, intent, due + 1)).assertFalse();
    });

    it('repairsInvalidSettingsAndBoundsReplayHistory', 0, (): void => {
      let saved = new CollectionReminderState();
      saved.hour = 99;
      saved.minute = -1;
      saved.lastCollectedAt = NaN;
      saved.handledDays = ['bad-date'];
      for (let i = 0; i < 120; i++) {
        saved.handledDays.push(collectionReminderDayKey(collectionReminderAddDays(localTime(2026, 1, 1), i)));
      }
      let normalized = normalizeCollectionReminderState(saved, 'new-plan');
      expect(normalized.hour).assertEqual(21);
      expect(normalized.minute).assertEqual(0);
      expect(normalized.lastCollectedAt).assertEqual(0);
      expect(normalized.planToken).assertEqual('new-plan');
      expect(normalized.handledDays.length).assertEqual(90);
    });

    it('reschedulesWhenDateTimeOrCollectionHistoryChanges', 0, (): void => {
      let state = enabledPlan();
      let now = localTime(2026, 10, 14, 12);
      let before = collectionReminderStamp(state, now);
      state.minute = 30;
      expect(collectionReminderStamp(state, now) !== before).assertTrue();
      state.minute = 0;
      state.lastCollectedAt = now;
      expect(collectionReminderStamp(state, now) !== before).assertTrue();
      state.lastCollectedAt = 0;
      expect(collectionReminderStamp(state, collectionReminderAddDays(now, 1)) !== before).assertTrue();
    });
  });
}
