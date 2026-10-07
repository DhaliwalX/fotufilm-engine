import { prepareVideoColor } from "../video-color-client.js";
import { GPU_WARMUP_GROUPS } from "../gpu-warmup.js";

// Progress counts finished compilation groups, never elapsed time.
export async function prepareEditor(renderer, report) {
  let film = {
    completed: 0,
    total: GPU_WARMUP_GROUPS,
    label: "Loading image engine",
  };
  let videoDone = false;
  const update = () =>
    report({
      value: Math.round(
        (100 * (film.completed + Number(videoDone))) / (film.total + 1),
      ),
      label:
        film.completed < film.total
          ? film.label
          : "Preparing video conversion",
      done: false,
    });
  update();
  await Promise.all([
    prepareVideoColor().then((available) => {
      videoDone = true;
      update();
      return available;
    }),
    renderer
      .prepare((state) => {
        film = state;
        update();
      })
      .catch((error) => {
        console.warn("Image engine preparation failed:", error);
        return false;
      })
      .then((available) => {
        film.completed = film.total;
        update();
        return available;
      }),
  ]);
  report({
    value: 100,
    label: "Ready",
    done: true,
  });
}
