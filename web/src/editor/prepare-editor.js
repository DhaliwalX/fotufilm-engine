import { GPU_WARMUP_GROUPS } from "../gpu-warmup.js";
import { assetUrl } from "../engine.js";
import { prepareNegativeWorker } from "../negative-worker-pool.js";

// Progress counts finished compilation groups, never elapsed time.
export async function prepareEditor(renderer, report) {
  let film = {
    completed: 0,
    total: GPU_WARMUP_GROUPS,
    label: "Loading image engine",
  };
  let negativeDone = false;
  const update = () =>
    report({
      value: Math.round(
        (100 * (film.completed + Number(negativeDone))) / (film.total + 1),
      ),
      label:
        film.completed < film.total
          ? film.label
          : "Preparing negative conversion",
      done: false,
    });
  update();
  await Promise.all([
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
    prepareNegativeWorker(assetUrl("negative/"))
      .catch(() => false)
      .then((available) => {
        negativeDone = true;
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
