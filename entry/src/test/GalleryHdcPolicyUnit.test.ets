import { describe, expect, it } from '@ohos/hypium';
import {
  GALLERY_HDC_MEDIA_ROOT, GALLERY_HDC_CHUNK_BYTES, GALLERY_HDC_MAX_IMAGE_BYTES,
  GalleryHdcEntry, galleryHdcCount, galleryHdcListing, galleryHdcLatest,
  galleryHdcMediaPath, galleryHdcImageExtension, galleryHdcChunkSize, galleryHdcChecksum,
  galleryHdcOwnedCopy, galleryHdcCanDiscardCopy, galleryImageDecodeSize
} from '../main/ets/utils/gallery/GalleryHdcPolicy';

function photo(name: string, time: number): GalleryHdcEntry {
  return { path: GALLERY_HDC_MEDIA_ROOT + '/' + name, directory: false, size: 1024, modifiedAt: time };
}

function rejectsCount(text: string): boolean {
  try { galleryHdcCount(text); return false; } catch (e) { return true; }
}

function rejectsLatest(entries: GalleryHdcEntry[], now: number): boolean {
  try { galleryHdcLatest(entries, 20, now); return false; } catch (e) { return true; }
}

export default function galleryHdcPolicyUnitTest(): void {
  describe('GalleryHdcPolicyUnitTest', (): void => {
    it('boundsUserSelectedBatchSize', 0, (): void => {
      expect(galleryHdcCount(' 20 ')).assertEqual(20);
      expect(galleryHdcCount('1')).assertEqual(1);
      expect(galleryHdcCount('500')).assertEqual(500);
      for (let text of ['', '0', '-1', '501', '1.5', '1e2', '20x']) { expect(rejectsCount(text)).assertTrue(); }
    });

    it('confinesAllPathsToTheMediaRoot', 0, (): void => {
      expect(galleryHdcMediaPath(GALLERY_HDC_MEDIA_ROOT)).assertTrue();
      expect(galleryHdcMediaPath(GALLERY_HDC_MEDIA_ROOT + '/相机/照片 1.jpg')).assertTrue();
      for (let suffix of ['/../private.jpg', '/./a.jpg', '/a\nb.jpg', '/a\u0000b.jpg']) {
        expect(galleryHdcMediaPath(GALLERY_HDC_MEDIA_ROOT + suffix)).assertFalse();
      }
      expect(galleryHdcMediaPath('/data/app/el2/private.jpg')).assertFalse();
      expect(galleryHdcMediaPath(GALLERY_HDC_MEDIA_ROOT + '_other/a.jpg')).assertFalse();
    });

    it('parsesDirectoriesUnicodeSpacesAndQuotesWithoutEvaluatingNames', 0, (): void => {
      let listing = 'total 12\n' +
        'drwxrwx--x 2 user_data_rw user_data_rw 3440 2026-10-15 09:10 16\n' +
        '-rw-rw---- 1 user_data_rw user_data_rw 6107481 2026-10-15 09:12:34 我的 \'相片\'.JPG\n' +
        'lrwxrwxrwx 1 shell shell 10 2026-10-15 09:12 outside -> /data/app\n';
      let parsed = galleryHdcListing(GALLERY_HDC_MEDIA_ROOT, listing);
      expect(parsed.length).assertEqual(2);
      expect(parsed[0].directory).assertTrue();
      expect(parsed[1].path).assertEqual(GALLERY_HDC_MEDIA_ROOT + '/我的 \'相片\'.JPG');
      expect(parsed[1].size).assertEqual(6107481);
      expect(parsed[1].modifiedAt).assertEqual(new Date(2026, 9, 15, 9, 12, 34).getTime());
    });

    it('failsClosedOnUnsupportedListingAndMalformedDates', 0, (): void => {
      let rejected = false;
      try { galleryHdcListing(GALLERY_HDC_MEDIA_ROOT, '[FAIL] permission denied'); }
      catch (e) { rejected = true; }
      expect(rejected).assertTrue();
      let parsed = galleryHdcListing(GALLERY_HDC_MEDIA_ROOT,
        '-rw-rw---- 1 user_data_rw user_data_rw 12 2026-02-30 09:12 image.jpg');
      expect(parsed[0].modifiedAt).assertEqual(0);
    });

    it('selectsGloballyAcrossAlbumsAndFiltersVideosBeforeApplyingN', 0, (): void => {
      let now = new Date(2026, 9, 15, 21).getTime();
      let entries: GalleryHdcEntry[] = [photo('1/a.jpg', now - 3000), photo('2/z.PNG', now - 1000),
        photo('1/video.mp4', now), photo('3/b.HEIC', now - 2000), photo('2/z.PNG', now - 1000)];
      let selected = galleryHdcLatest(entries, 2, now);
      expect(selected.length).assertEqual(2);
      expect(selected[0].path).assertEqual(GALLERY_HDC_MEDIA_ROOT + '/2/z.PNG');
      expect(selected[1].path).assertEqual(GALLERY_HDC_MEDIA_ROOT + '/3/b.HEIC');
      expect(galleryHdcLatest(entries, 20, now).length).assertEqual(3);
      expect(galleryHdcImageExtension('PHOTO.HEIF')).assertEqual('.heif');
      expect(galleryHdcImageExtension('movie.mp4')).assertEqual('');
    });

    it('doesNotPretendEpochOrFutureTimestampsRepresentLatestPhotos', 0, (): void => {
      let now = Date.now();
      expect(rejectsLatest([photo('a.jpg', now), photo('b.jpg', 0)], now)).assertTrue();
      expect(rejectsLatest([photo('a.jpg', now + 2 * 86400000)], now)).assertTrue();
      let epoch = galleryHdcListing(GALLERY_HDC_MEDIA_ROOT,
        '-rw-rw-rw- 1 user_data_rw user_data_rw 100 1970-01-01 00:00 a.jpg');
      expect(rejectsLatest(epoch, now)).assertTrue();
      let ties = galleryHdcLatest([photo('z.jpg', now), photo('a.jpg', now)], 1, now);
      expect(ties[0].path).assertEqual(GALLERY_HDC_MEDIA_ROOT + '/a.jpg');
    });

    it('chunksLargeOriginalsIncludingExactAndPartialBoundaries', 0, (): void => {
      let chunk = GALLERY_HDC_CHUNK_BYTES;
      expect(galleryHdcChunkSize(chunk, 0)).assertEqual(chunk);
      expect(galleryHdcChunkSize(chunk + 1, 1)).assertEqual(1);
      expect(galleryHdcChunkSize(20 * 1024 * 1024 + 17, 80)).assertEqual(17);
      expect(galleryHdcChunkSize(GALLERY_HDC_MAX_IMAGE_BYTES, 255)).assertEqual(chunk);
      for (let size of [0, -1, GALLERY_HDC_MAX_IMAGE_BYTES + 1, NaN]) {
        let rejected = false;
        try { galleryHdcChunkSize(size, 0); } catch (e) { rejected = true; }
        expect(rejected).assertTrue();
      }
      let rejected = false;
      try { galleryHdcChunkSize(chunk, 1); } catch (e) { rejected = true; }
      expect(rejected).assertTrue();
    });

    it('requiresASha256ChecksumBeforeUsingAnExport', 0, (): void => {
      let digest = 'a'.repeat(64);
      expect(galleryHdcChecksum(digest.toUpperCase() + '  /data/local/tmp/export.img\n')).assertEqual(digest);
      let rejected = false;
      try { galleryHdcChecksum('sha256sum: Permission denied'); } catch (e) { rejected = true; }
      expect(rejected).assertTrue();
    });

    it('onlyDiscardsFeatureOwnedFullCopiesWithAMatchingThumbnailAndOriginalReference', 0, (): void => {
      let files = '/data/storage/el2/base/haps/entry/files';
      let id = 'gallery_hdc_' + 'a'.repeat(64) + '_' + 'b'.repeat(64);
      let copy = files + '/gallery-log/hdc-images/' + id + '.heic';
      let thumbnail = files + '/gallery-log/thumbnails/' + id + '.jpg';
      let source = GALLERY_HDC_MEDIA_ROOT + '/1/原图.heic';
      expect(galleryHdcOwnedCopy(files, copy)).assertTrue();
      expect(galleryHdcCanDiscardCopy(files, copy, source, thumbnail)).assertTrue();
      expect(galleryHdcCanDiscardCopy(files, copy, '', thumbnail)).assertFalse();
      expect(galleryHdcCanDiscardCopy(files, copy, '/data/other/photo.jpg', thumbnail)).assertFalse();
      expect(galleryHdcCanDiscardCopy(files, copy, source, thumbnail.replace('a'.repeat(64), 'c'.repeat(64)))).assertFalse();
      expect(galleryHdcCanDiscardCopy(files, copy, source, files + '/elsewhere/thumb.jpg')).assertFalse();
      for (let path of [source, files + '/gallery-log/hdc-images/../photo.jpg', copy + '.part',
        files + '/gallery-log/hdc-images/nested/' + id + '.heic', copy.replace('/hdc-images/', '/hdc-images-other/')]) {
        expect(galleryHdcOwnedCopy(files, path)).assertFalse();
        expect(galleryHdcCanDiscardCopy(files, path, source, thumbnail)).assertFalse();
      }
    });

    it('preservesAspectRatioAndBoundsThumbnailAndPreviewAllocations', 0, (): void => {
      let landscape = galleryImageDecodeSize(8000, 6000, 384);
      expect(landscape.width).assertEqual(384); expect(landscape.height).assertEqual(288);
      let portrait = galleryImageDecodeSize(6000, 8000, 2048);
      expect(portrait.width).assertEqual(1536); expect(portrait.height).assertEqual(2048);
      let small = galleryImageDecodeSize(80, 60, 384);
      expect(small.width).assertEqual(80); expect(small.height).assertEqual(60);
      expect(galleryImageDecodeSize(1, 200000, 384).width).assertEqual(1);
      for (let value of [0, -1, NaN, Infinity, 0.5]) {
        let rejected = false;
        try { galleryImageDecodeSize(value, 100, 384); } catch (e) { rejected = true; }
        expect(rejected).assertTrue();
      }
    });
  });
}
