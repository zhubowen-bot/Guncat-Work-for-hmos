export declare namespace image {
  interface Size { width: number; height: number; }
  interface DecodingOptions { desiredSize?: Size; }
  interface PackingOption { format: string; quality: number; }
  class PixelMap { release(): Promise<void>; }
  class ImageSource { createPixelMap(opts?: DecodingOptions): Promise<PixelMap>; release(): Promise<void>; }
  class ImagePacker { packToData(pixelMap: PixelMap, opts: PackingOption): Promise<ArrayBuffer>; release(): Promise<void>; }
  function createImageSource(fd: number): ImageSource;
  function createImagePacker(): ImagePacker;
}
