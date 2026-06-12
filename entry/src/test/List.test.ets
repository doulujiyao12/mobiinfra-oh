import localUnitTest from './LocalUnit.test';
import dataManagerUnitTest from './DataManagerUnit.test';
import workflowStorageUnitTest from './WorkflowStorageUnit.test';
import workflowDateContextUnitTest from './WorkflowDateContextUnit.test';
import mainTabConfigUnitTest from './MainTabConfigUnit.test';
import chatPageTypesUnitTest from './ChatPageTypesUnit.test';
import settingsCenterConfigUnitTest from './SettingsCenterConfigUnit.test';
import chatSessionStorageUnitTest from './ChatSessionStorageUnit.test';
import appLoggerUnitTest from './AppLoggerUnit.test';
import appBackupUnitTest from './AppBackupUnit.test';
import textEncodingCompatUnitTest from './TextEncodingCompatUnit.test';

export default function testsuite() {
  localUnitTest();
  dataManagerUnitTest();
  workflowStorageUnitTest();
  workflowDateContextUnitTest();
  mainTabConfigUnitTest();
  chatPageTypesUnitTest();
  settingsCenterConfigUnitTest();
  chatSessionStorageUnitTest();
  appLoggerUnitTest();
  appBackupUnitTest();
  textEncodingCompatUnitTest();
}
