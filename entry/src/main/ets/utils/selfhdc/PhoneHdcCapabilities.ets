import { selfHdcHasCommandFailure } from './SelfHdcPolicy';

export interface PhoneHdcUiInputHelp {
  commands: string[];
  acceptedNonzeroExit: boolean;
}

// This policy is only for the read-only `uitest uiInput help` probe, never for device actions.
export function parsePhoneHdcUiInputHelp(exitCode: number, output: string): PhoneHdcUiInputHelp {
  if (exitCode !== 0 && exitCode !== 1) {
    throw new Error('PHONE_HDC_CAPABILITY: uiInput help unexpected exit=' + exitCode);
  }
  let header = /^[ \t]*USAGE[ \t]*:[ \t]*$/mi.exec(output);
  if (!header) { throw new Error('PHONE_HDC_CAPABILITY: uiInput help has no USAGE section; exit=' + exitCode); }
  let banner = output.substring(0, header.index).trim();
  // API26's help prints "Missing parameter." and the full usage, then exits 1.
  if (banner && !/^Missing\s+parameter\.?$/i.test(banner) && !/^No Error$/i.test(banner)) {
    throw new Error('PHONE_HDC_CAPABILITY: uiInput help has an unexpected error/banner; exit=' + exitCode);
  }
  let usage = output.substring(header.index);
  if (selfHdcHasCommandFailure(usage) || /permission denied|not permitted|not found|no such file|not supported|segmentation fault/i.test(usage)) {
    throw new Error('PHONE_HDC_CAPABILITY: uiInput help reports a real error; exit=' + exitCode);
  }
  let commands: string[] = ['click', 'swipe', 'text', 'keyEvent'];
  for (let command of commands) {
    // Match a subcommand declaration, including "click/doubleClick/longClick" and "swipe/drag".
    // A word in a description or the distinct inputText command does not prove support for text.
    if (!new RegExp('^[ \\t]*' + command + '(?:/[A-Za-z]+)*[ \\t]+<', 'mi').test(usage)) {
      throw new Error('PHONE_HDC_CAPABILITY: uiInput help missing ' + command + '; no device action sent');
    }
  }
  return { commands: commands, acceptedNonzeroExit: exitCode === 1 };
}
