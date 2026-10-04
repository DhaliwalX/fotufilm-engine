import { useEffect, useRef, useState } from "react";

// Thumbnails show the film's colour and tone only: halation and grain are left off.
export const thumbnailEdit = (edit) => ({
  ...edit,
  halationModel: "legacy",
  profile: { ...edit.profile, halation: 0 },
  params: { ...edit.params, grain: 0 },
});

// A small background render of `image` under `edit` once `ref`'s element scrolls into view, for the
// film column and the format grid. The last thumbnail stays up until the next one arrives, and
// another photograph's never stands in for this one's.
export function useThumbnail({ image, session, edit, stock, videoTime, maxEdge }) {
  const ref = useRef(null),
    [thumbnail, setThumbnail] = useState(null);
  const shown = JSON.stringify(edit);
  useEffect(() => {
    if (!image || !session) return;
    let cancelled = false,
      timer;
    const observer = new IntersectionObserver((entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return;
      observer.disconnect();
      // Wait until the main preview has been queued before thumbnail work.
      timer = setTimeout(
        () =>
          session
            .render({
              image,
              stock,
              edit: thumbnailEdit(JSON.parse(shown)),
              videoTime,
              maxEdge,
              background: true,
              stale: () => cancelled,
            })
            .then((result) => {
              if (!result || cancelled) return;
              const url = URL.createObjectURL(result.blob);
              setThumbnail((previous) => {
                if (previous) URL.revokeObjectURL(previous.url);
                return { image, url };
              });
            })
            .catch(() => {}),
        400,
      );
    });
    observer.observe(ref.current);
    return () => {
      cancelled = true;
      clearTimeout(timer);
      observer.disconnect();
    };
  }, [image, session, stock, maxEdge, shown, videoTime]);
  useEffect(
    () => () =>
      setThumbnail((previous) => {
        if (previous) URL.revokeObjectURL(previous.url);
        return null;
      }),
    [image],
  );
  return { ref, url: thumbnail && thumbnail.image === image ? thumbnail.url : null };
}

// What the thumbnails show, as the Mac app's previews follow the editor: the photograph at once
// when it changes, the edit and a clip's paused frame 650 ms after they last moved. A clip is
// left out where the backend does not develop video natively.
export function useThumbnailSource({ active, edit, videoTime, backend }) {
  const image =
    active?.image.video && backend.kind !== "native" ? null : active?.image;
  const value = {
    image,
    edit,
    videoTime: active?.image.video ? videoTime : undefined,
  };
  const [settled, setSettled] = useState(value);
  const latest = useRef(value);
  latest.current = value;
  const key = JSON.stringify({ edit, videoTime: value.videoTime });
  const imageChanged = settled.image !== image;
  useEffect(() => {
    if (imageChanged) {
      setSettled(latest.current);
      return;
    }
    const timer = setTimeout(() => setSettled(latest.current), 650);
    return () => clearTimeout(timer);
  }, [key, imageChanged]);
  return imageChanged ? value : settled;
}
