export declare namespace http {
  enum RequestMethod { GET = 'GET', POST = 'POST' }
  enum HttpDataType { STRING = 0, ARRAY_BUFFER = 1 }
  enum HttpProtocol { HTTP1_1 = 'HTTP/1.1', HTTP2 = 'HTTP/2', HTTP3 = 'HTTP/3', NONE = 'NONE' }
  interface HttpRequestOptions { method?: string; header?: object | string; extraData?: object | string;
    expectDataType?: number; usingCache?: boolean; usingProtocol?: HttpProtocol;
    connectTimeout?: number; readTimeout?: number; }
  interface HttpResponse { responseCode: number; result: Object; header: Object; }
  interface HttpRequest { request(url: string, options: HttpRequestOptions): Promise<HttpResponse>; destroy(): void; }
  function createHttp(): HttpRequest;
}
