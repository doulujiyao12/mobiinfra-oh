export function withTimeout<T>(operation: Promise<T>, milliseconds: number, message: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer: number = setTimeout(() => reject(new Error(message)), milliseconds);
    operation.then((value: T) => { clearTimeout(timer); resolve(value); },
      (error: Error) => { clearTimeout(timer); reject(error); });
  });
}
