export const AI_GENERATED_LABEL_TEXT: string = 'AI生成';
export const AI_GENERATED_TEXT_NOTICE: string = '【AI生成内容】';
export const AI_GENERATED_SERVICE_PROVIDER: string = 'MobiInfer LLM Chat';
export const AI_GENERATED_CONTENT_PROPERTY: string = 'ai_generated';

export interface AiGeneratedContentMetadata {
  generatedContent: boolean;
  contentProperty: string;
  serviceProvider: string;
  contentId: string;
  generatedAt: string;
  explicitLabel: string;
}

export function createAiGeneratedContentMetadata(contentId: string,
  generatedAt: string): AiGeneratedContentMetadata {
  return {
    generatedContent: true,
    contentProperty: AI_GENERATED_CONTENT_PROPERTY,
    serviceProvider: AI_GENERATED_SERVICE_PROVIDER,
    contentId: contentId,
    generatedAt: generatedAt,
    explicitLabel: AI_GENERATED_TEXT_NOTICE
  };
}

export function isAiGeneratedChatMessage(role: string, kind: string): boolean {
  if (kind === 'context_notice') {
    return false;
  }
  return role === 'assistant' || role === 'task' || kind === 'task_result' || kind === 'task_trace';
}

export function ensureAiGeneratedTextNotice(text: string): string {
  let normalized = text.trim();
  if (normalized.length === 0 || normalized.startsWith(AI_GENERATED_TEXT_NOTICE)) {
    return normalized;
  }
  return AI_GENERATED_TEXT_NOTICE + '\n' + normalized;
}
