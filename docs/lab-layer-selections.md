# Layered Lab selection masks

Layered Lab documents can use rectangle, ellipse and lasso selections, and
Select All, None and Invert. These operations change only the image's root
selection mask and use the native selection Undo/Redo history; they do not
interpret or change the logical layers' Lab planes. Other selection commands
remain unavailable for this layout.

The engine advertises this behavior with the separate
`GLIMS_IMAGE_STORAGE_LAB_SELECTIONS` capability. An older adapter without that
flag leaves these tools and menu items disabled. The app also gates the
commands while the document or engine is busy, while a stroke or target
change is pending, and during Recorder recording or replay; layered Lab
selection recording and replay are not implemented here.

The native regression exercises mask bounds, Undo/Redo, busy admission and
pixel preservation, while the real-window fixture covers menu selection and
a canvas rectangle gesture. This is one limited editing capability; layered
Lab painting and full editor qualification remain separate work.
