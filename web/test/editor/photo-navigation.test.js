import test from "node:test";
import assert from "node:assert/strict";
import {
  anchoredPhotoZoom,
  constrainPhotoOffset,
  pinchGeometry,
} from "../../src/photo-navigation.js";
import { renderViewportImage } from "../../src/viewport-detail-image.js";

const view = {
  zoom: 2,
  offset: [20, -10],
  display: [800, 600],
  room: [600, 400],
};
test("zoom preserves the source point under the cursor or moving pinch midpoint", () => {
  const anchor = [120, -30],
    nextAnchor = [150, -10];
  const zoom = anchoredPhotoZoom({ ...view, anchor, nextAnchor, scale: 1.5 });
  assert.equal(zoom.zoom, 3);
  for (let axis = 0; axis < 2; axis++)
    assert.equal(
      (anchor[axis] - view.offset[axis]) / view.zoom,
      (nextAnchor[axis] - zoom.offset[axis]) / zoom.zoom,
    );
  assert.deepEqual(
    pinchGeometry([
      [20, 40],
      [100, 40],
    ]),
    { anchor: [60, 40], distance: 80 },
  );
});

test("pan and pinch bounds keep the visible image on screen and return to centred fit", () => {
  assert.deepEqual(
    constrainPhotoOffset([999, -999], 2, [800, 600], [600, 400]),
    [500, -400],
  );
  const fit = anchoredPhotoZoom({
    ...view,
    display: [550, 350],
    anchor: [120, 0],
    scale: 0.01,
  });
  assert.deepEqual(fit, { zoom: 1, offset: [0, 0] });
  assert.equal(
    anchoredPhotoZoom({ ...view, anchor: [0, 0], scale: 100 }).zoom,
    8,
  );
});

for (const outcome of ["stale", "decode error", "ready"])
  test(`detail blobs are released after ${outcome}`, async (t) => {
    const revoked = [];
    let stale = false;
    const OldImage = globalThis.Image;
    globalThis.Image = class {
      async decode() {
        if (outcome === "stale") stale = true;
        if (outcome === "decode error") throw Error("decode failed");
      }
    };
    t.after(() => {
      if (OldImage) globalThis.Image = OldImage;
      else delete globalThis.Image;
    });
    const original = URL.revokeObjectURL;
    t.mock.method(URL, "revokeObjectURL", (url) => {
      revoked.push(url);
      original(url);
    });
    const session = {
      render: async () => ({
        blob: new Blob(["image"]),
        original: new Blob(["original"]),
      }),
    };
    const promise = renderViewportImage(session, {}, {}, () => stale);
    if (outcome === "decode error")
      await assert.rejects(promise, /decode failed/);
    else {
      const detail = await promise;
      if (outcome === "ready") {
        assert.equal(revoked.length, 0);
        detail.dispose();
      } else assert.equal(detail, null);
    }
    assert.equal(new Set(revoked).size, 2);
  });
