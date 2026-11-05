export const CODEX_DELIVERY_POLICY: string = '交付要求：完成后简述结果和验证情况。需要交付可阅读的文字文档时生成真正的 Word（.docx），' +
  '不要以 .txt 或 .md 作为最终文档；适合演示、汇报的材料优先生成 PowerPoint（.pptx）。不要仅改扩展名。' +
  '简短答复可直接在对话中给出，不必强行生成文件；程序源码、配置及数据保留所需的原始格式。' +
  '成品优先保存到工作目录 outputs/，只为最终交付文件提供绝对路径 Markdown 链接，不链接临时文件、凭据或依赖。';

export function codexTaskWithDeliveryPolicy(task: string): string { return task + '\n\n' + CODEX_DELIVERY_POLICY; }
