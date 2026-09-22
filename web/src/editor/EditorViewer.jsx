import StartupProgress from "./StartupProgress.jsx";
import { AnimatePresence, motion } from "motion/react";
import Presence from "../Presence.jsx";
import { Icon } from "../icons.jsx";
import { ImageCanvas } from "../ImageCanvas.jsx";
import { frameSamplePoint } from "../print-frame.js";
import { newSelection, sampleScene } from "../selective.js";
import VideoControls from "../VideoControls.jsx";
import { Button } from "@react-spectrum/s2/Button";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import ViewerStatus from "./ViewerStatus.jsx";
import PhotoStrip from "./PhotoStrip.jsx";
import { useEditor } from "./EditorContext.jsx";
export default function EditorViewer() {
  const {
    startupProgress,
    dragOver,
    setDragOver,
    acceptFiles,
    active,
    sampling,
    shownResult,
    edit,
    patch,
    setSampling,
    setError,
    setDetailBackend,
    session,
    detailRequest,
    previewInteracting,
    exporting,
    previewKey,
    setViewerMoving,
    zoom,
    cropMode,
    width,
    cropSize,
    setZoomReadout,
    setZoom,
    compare,
    setCompare,
    activeId,
    endEdit,
    histogram,
    setHistogram,
    videoTime,
    setVideoTime,
    openFiles,
    importStatus,
    importController,
    setImportStatus,
    visibleError,
    setRetry,
    setLibraryError,
    files,
  } = useEditor();
  return (
    <main
      className={`viewer ${dragOver ? "drag-over" : ""}`}
      aria-label="Photo and video editor"
      onDragOver={(e) => {
        e.preventDefault();
        setDragOver(true);
      }}
      onDragLeave={(e) => {
        if (!e.currentTarget.contains(e.relatedTarget)) setDragOver(false);
      }}
      onDrop={(e) => {
        e.preventDefault();
        setDragOver(false);
        acceptFiles(e.dataTransfer.files);
      }}
    >
      <StartupProgress progress={startupProgress} />
      <AnimatePresence mode="wait" initial={false}>
        {active ? (
          <motion.div
            className="viewer-content"
            key={active.id}
            initial={{
              opacity: 0,
            }}
            animate={{
              opacity: 1,
            }}
            exit={{
              opacity: 0,
            }}
          >
            <>
              <ImageCanvas
                sampling={sampling}
                onSample={(point) => {
                  if (!shownResult?.sceneSource) return;
                  point = frameSamplePoint(point, shownResult.framePlan);
                  if (!point) return;
                  const selective = edit.selective || newSelection(edit);
                  patch({
                    selective: {
                      ...selective,
                      point,
                      sample: sampleScene(shownResult.sceneSource, point),
                    },
                  });
                  setSampling(false);
                }}
                onDetailError={setError}
                onDetailBackend={setDetailBackend}
                detailSession={session}
                detailRequest={detailRequest}
                detailEnabled={
                  !previewInteracting &&
                  !exporting &&
                  shownResult?.key === previewKey
                }
                result={shownResult}
                original={active.image}
                sourceKey={active.id}
                onInteraction={setViewerMoving}
                zoom={zoom}
                outputWidth={
                  cropMode
                    ? width
                    : cropSize.width *
                      (shownResult?.framePlan
                        ? shownResult.width /
                          shownResult.framePlan.placement.image.width
                        : 1)
                }
                onZoomReadout={setZoomReadout}
                setZoom={setZoom}
                compare={compare}
                setCompare={setCompare}
                cropMode={cropMode}
                crop={edit.crop}
                cropShape={edit.cropShape}
                cropRatio={edit.ratio}
                cropIdentity={JSON.stringify([
                  activeId,
                  edit.rotation,
                  edit.flip,
                  edit.straighten,
                  edit.perspectiveV,
                  edit.perspectiveH,
                ])}
                onCrop={(crop) =>
                  patch(
                    {
                      crop,
                    },
                    "crop",
                  )
                }
                onEnd={endEdit}
                showHistogram={histogram ? () => setHistogram(false) : null}
              />
              {active.image.video && (
                <VideoControls
                  key={active.id}
                  clip={active.image.video}
                  time={videoTime}
                  onTime={setVideoTime}
                  settings={edit.video}
                  onChange={(video) =>
                    patch({
                      video,
                    })
                  }
                  disabled={exporting || cropMode}
                />
              )}
            </>
          </motion.div>
        ) : (
          <motion.div
            className="empty-canvas"
            key="empty"
            initial={{
              opacity: 0,
            }}
            animate={{
              opacity: 1,
            }}
            exit={{
              opacity: 0,
            }}
          >
            <Button size="S" onPress={() => openFiles()} variant={"accent"}>
              Open image or video
            </Button>
            <p>or drop files here</p>
          </motion.div>
        )}
      </AnimatePresence>
      <Presence show={!!importStatus} className="import-status" role="status">
        <span>{importStatus}</span>
        <ActionButton
          size="S"
          onPress={() => {
            importController.current?.abort();
            setImportStatus(null);
          }}
          isQuiet
        >
          {"Cancel"}
        </ActionButton>
      </Presence>
      <Presence show={!!dragOver} className="drop-label">
        Drop images to open
      </Presence>
      <Presence show={!!visibleError} className="error-banner" role="alert">
        <span>{visibleError}</span>
        <ActionButton
          size="S"
          onPress={() => {
            setError(null);
            setRetry((v) => v + 1);
          }}
          isQuiet
        >
          {"Retry"}
        </ActionButton>
        <ActionButton
          aria-label="Dismiss error"
          onPress={() => {
            setError(null);
            setLibraryError(null);
          }}
          size={"S"}
        >
          <Icon name="close" size={14} />
        </ActionButton>
      </Presence>
      <ViewerStatus />
      <Presence show={files.length > 1}>
        <PhotoStrip />
      </Presence>
    </main>
  );
}
