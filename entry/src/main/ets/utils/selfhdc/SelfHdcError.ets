import { BusinessError } from '@kit.BasicServicesKit';

export function selfHdcErrorText(error: Error): string {
  let code = (error as BusinessError).code;
  return (code !== undefined ? 'code=' + String(code) + ' ' : '') + error.message;
}
