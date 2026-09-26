import { memo, useEffect, useState } from "react";
import { Icon } from "../icons.jsx";

function useThumbnail(thumbnails, photo) {
  // A retained thumbnail shows at once, without fading in again on scroll.
  const [state, setState] = useState(() => ({
    url: thumbnails?.peek(photo) ?? null,
    fresh: false,
  }));
  useEffect(() => {
    if (!thumbnails || state.url) return;
    let live = true;
    const request = thumbnails.request(photo);
    request.promise.then(
      ({ url, fresh }) => live && setState({ url: url || false, fresh }),
    );
    return () => {
      live = false;
      request.cancel();
    };
  }, [thumbnails, photo.key, photo.size, photo.modified]);
  return state;
}

function Stars({ rating, onRate }) {
  return (
    <span className="library-stars" data-rated={rating > 0 || undefined}>
      {[1, 2, 3, 4, 5].map((value) => (
        <button
          key={value}
          type="button"
          tabIndex={-1}
          aria-label={`${value} star${value > 1 ? "s" : ""}`}
          className={value <= rating ? "on" : ""}
          onPointerDown={(event) => event.stopPropagation()}
          onClick={(event) => {
            event.stopPropagation();
            onRate(value === rating ? 0 : value);
          }}
        >
          <Icon name={value <= rating ? "starFilled" : "star"} size={13} />
        </button>
      ))}
    </span>
  );
}

const extension = (name) => name.split(".").at(-1).toUpperCase();

export default memo(function PhotoTile({
  id,
  photo,
  x,
  y,
  size,
  selected,
  focused,
  rating,
  edited,
  thumbnails,
  onPress,
  onOpen,
  onRate,
}) {
  const { url, fresh } = useThumbnail(thumbnails, photo);
  const [loaded, setLoaded] = useState(false);
  return (
    <div
      id={id}
      role="option"
      aria-selected={selected}
      aria-label={photo.name}
      data-key={photo.key}
      className={`library-tile${selected ? " selected" : ""}${focused ? " focused" : ""}`}
      style={{
        width: size,
        height: size,
        transform: `translate3d(${x}px, ${y}px, 0)`,
      }}
      onPointerDown={(event) => event.button === 0 && onPress(photo.key, event)}
      onDoubleClick={() => onOpen(photo.key)}
    >
      <div className="library-thumb">
        {url ? (
          <img
            src={url}
            alt=""
            draggable={false}
            decoding="async"
            className={fresh && !loaded ? "entering" : undefined}
            onLoad={() => setLoaded(true)}
          />
        ) : (
          <span
            className={`library-placeholder${url === false ? " none" : ""}`}
          >
            {url === false && extension(photo.name)}
          </span>
        )}
      </div>
      <div className="library-tile-meta">
        <span className="library-name">{photo.name}</span>
        <Stars rating={rating} onRate={(value) => onRate(photo.key, value)} />
      </div>
      {(edited || photo.kind !== "image") && (
        <span className="library-badges">
          {photo.kind === "raw" && <span className="library-badge">RAW</span>}
          {photo.kind === "video" && (
            <span className="library-badge">Video</span>
          )}
          {edited && (
            <span className="library-badge edited" title="Edited">
              <Icon name="edited" size={12} />
            </span>
          )}
        </span>
      )}
    </div>
  );
});
