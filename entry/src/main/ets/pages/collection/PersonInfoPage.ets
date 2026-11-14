import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { AppTheme } from '../../utils/AppTheme';
import { FrostedPage } from '../../components/FrostedPage';
import { APP_HEADER_CONTENT_GAP, APP_HEADER_HEIGHT } from '../../components/AppHeader';
import { CollectionFormGroup, CollectionFormInput, CollectionFormDivider } from '../../components/CollectionFormControls';
import { MemoryPerson, PersonField, PERSON_FIELDS, PERSON_MEMORY_REVISION_KEY, personSlot, emptyMemoryPerson, samePersonValues } from '../../datamanager/PersonMemory';
import { PersonMemoryStore } from '../../datamanager/PersonMemoryStore';
import { StringMap } from '../../datamanager/DataManagerTypes';

interface PersonPageParams { personId?: string; }
@Entry
@Component
struct PersonInfoPage {
  private scroller: Scroller = new Scroller();
  private filesDir: string = '';
  @State private person: MemoryPerson = emptyMemoryPerson(personSlot('person:self'));
  @State private values: StringMap = {};
  @State private ready: boolean = false;
  @State private dirty: boolean = false;
  @State private error: string = '';
  aboutToAppear(): void {
    try {
      this.filesDir = (this.getUIContext().getHostContext() as common.UIAbilityContext).filesDir;
      const params = router.getParams() as PersonPageParams;
      const id = params?.personId || 'person:self'; personSlot(id);
      this.person = new PersonMemoryStore(this.filesDir).people().find((person: MemoryPerson): boolean => person.id === id) as MemoryPerson;
      this.values = this.copyValues(this.person.values); this.ready = true; this.dirty = false;
    } catch (e) { this.error = '资料读取失败，请返回后重试'; }
  }
  private copyValues(source: StringMap): StringMap {
    const copy: StringMap = {}; Object.keys(source).forEach((key: string): void => { copy[key] = source[key]; }); return copy;
  }
  private edit(field: PersonField, value: string): void {
    const next = this.copyValues(this.values); next[field.key] = value; this.values = next;
    this.dirty = !samePersonValues(this.person.values, next); this.error = '';
  }
  private goBack(): void {
    if (!this.dirty) { router.back(); return; }
    AlertDialog.show({ title: '尚未保存', message: '要放弃这次修改吗？',
      primaryButton: { value: '继续编辑', action: (): void => {} },
      secondaryButton: { value: '放弃修改', action: (): void => { this.dirty = false; router.back(); } } });
  }
  onBackPress(): boolean { this.goBack(); return true; }
  private save(): void {
    if (!this.ready) { return; }
    try {
      this.person = new PersonMemoryStore(this.filesDir).save(this.person.id, this.values, this.person.revision);
      AppStorage.setOrCreate(PERSON_MEMORY_REVISION_KEY, Date.now()); this.dirty = false;
      this.getUIContext().getPromptAction().showToast({ message: '已保存到记忆', duration: 1400 }); router.back();
    } catch (e) { this.error = (e as Error).message || '保存失败，请重试'; }
  }
  @Builder private Header() {
    Row() {
      Row() {
        Button('‹', { type: ButtonType.Circle }).width(40).height(40).fontSize(30)
          .fontColor(AppTheme.text('#172033')).backgroundColor(Color.Transparent).onClick((): void => { this.goBack(); })
          .accessibilityText('返回人物资料')
      }.width(64)
      Text(this.person.label).fontSize(19).fontWeight(FontWeight.Medium).textAlign(TextAlign.Center).layoutWeight(1)
        .fontColor(AppTheme.text('#172033'))
      Button('保存').height(40).width(64).fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(AppTheme.text(this.ready && this.dirty ? '#007AFF' : '#A2A9B4')).backgroundColor(Color.Transparent)
        .enabled(this.ready && this.dirty).onClick((): void => { this.save(); })
    }.width('100%').height(APP_HEADER_HEIGHT).padding({ left: 12, right: 12 })
  }
  @Builder private FieldGroup(group: string) {
    // A trailing builder closure is compiled as UI. A regular callback containing
    // ForEach directly does not construct the input nodes in this container.
    CollectionFormGroup({ title: group }) {
      ForEach(PERSON_FIELDS.filter((field: PersonField): boolean => field.group === group), (field: PersonField, index: number) => {
        if (index > 0) { CollectionFormDivider() }
        CollectionFormInput({ label: field.label, value: this.values[field.key] || '', placeholder: field.placeholder,
          multiline: field.multiline, limit: field.limit, onChangeValue: (value: string): void => { this.edit(field, value); } })
      }, (field: PersonField): string => field.key)
    }
  }
  @Builder private Content() {
    Scroll(this.scroller) {
      Column() {
        if (this.ready) {
          this.FieldGroup('基本信息')
          this.FieldGroup('工作与生活')
          this.FieldGroup('联系方式')
          this.FieldGroup('补充')
        }
        if (this.error) { Text(this.error).fontSize(14).fontColor(AppTheme.text('#C34D60')).width('100%').padding({ bottom: 20 }) }
        Blank().height(32)
      }.width('92%').constraintSize({ maxWidth: 720 }).padding({ top: APP_HEADER_CONTENT_GAP + 12 })
    }.width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.Top)
  }
  build() {
    Column() {
      FrostedPage({ pageBackgroundColor: '#F4F6FA', scrollers: [this.scroller],
        headerBuilder: (): void => { this.Header(); }, contentBuilder: (): void => { this.Content(); } })
    }.width('100%').height('100%')
  }
}
