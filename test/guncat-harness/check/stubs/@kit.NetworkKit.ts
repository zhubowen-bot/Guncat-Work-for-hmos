export declare namespace http {
  enum RequestMethod { GET = 'GET', POST = 'POST' }
  enum HttpDataType { STRING = 0, ARRAY_BUFFER = 1 }
  enum HttpProtocol { HTTP1_1 = 0, HTTP2 = 1 }
  interface HttpResponse { responseCode: number; result: Object; header: Object; }
  interface HttpRequestOptions {
    method?: RequestMethod;
    header?: Record<string, string>;
    extraData?: string;
    connectTimeout?: number;
    readTimeout?: number;
    usingProtocol?: HttpProtocol;
  }
  interface HttpRequest {
    request(url: string, options: object): Promise<HttpResponse>;
    requestInStream(url: string, options: object): Promise<number>;
    destroy(): void;
    on(type: string, cb: (data: object) => void): void;
    off(type: string): void;
  }
  function createHttp(): HttpRequest;
}
