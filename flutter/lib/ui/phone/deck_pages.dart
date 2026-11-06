// What each page of the phone's sheet holds: sections of the inspector's panels, regrouped by
// what they act on. The sections are the desktop's own, so they behave the same.
import 'package:flutter/widgets.dart';

import '../../model/phone_decks.dart';
import '../inspector/controls.dart';
import '../inspector/crop_panel.dart';
import '../inspector/develop_panel.dart';
import '../inspector/expose_panel.dart';
import '../inspector/film_panel.dart';
import '../inspector/lens_filters.dart';
import '../inspector/lens_section.dart';
import '../inspector/negative_panel.dart';
import '../inspector/print_frame_section.dart';
import '../inspector/print_panel.dart';
import '../inspector/roll_panel.dart';
import '../inspector/selective_panel.dart';
import '../inspector/tone_curve_chart.dart';
import '../kit/kit.dart';
import 'phone_films.dart';

List<Widget> deckPage(DeckPage page, InspectorControls c) => switch (page) {
      DeckPage.films => [PhoneFilms(editor: c.editor)],
      DeckPage.halation => [halationSection(c)],
      DeckPage.emulsion => [?colourSeparationSection(c)],
      DeckPage.lab => [developmentSection(c), ?filmConditionSection(c), ?longExposureSection(c)],
      DeckPage.format => [?filmFormatSection(c)],
      DeckPage.negative => [negativeFilmSection(c)],
      DeckPage.filmBase => [filmBaseSection(c)],
      DeckPage.scanColour => [scanColourSection(c)],
      DeckPage.lightSource => [?lightSourceSection(c)],
      DeckPage.roll => rollPanel(c),
      DeckPage.grain => c.hasFilm
          ? [...grainControls(c), newGrainPatternButton(c)]
          : const [Note('Choose a film in the Film Strip to give the photograph its grain.')],
      DeckPage.grainModel => grainModelControls(c),
      DeckPage.grainAdjust => filmGrainControls(c),
      DeckPage.filters => [lensFiltersSection(c)],
      DeckPage.correction => [LensSection(editor: c.editor)],
      // The phone has no inspector heading to chart the tone curve above, so Output shows it.
      DeckPage.output => [
          ToneCurveChart(editor: c.editor),
          ...printOutputControls(c),
          // The engine develops in Display P3, the space the canvas shows in.
          const InfoRow('Color space', 'Display P3'),
        ],
      DeckPage.printAdjust => printAdjustControls(c),
      DeckPage.frame => [PrintFrameSection(editor: c.editor)],
      DeckPage.lamp => [?lampSection(c)],
      DeckPage.exposure => [lightSection(c)],
      DeckPage.balance => [?sourceIlluminantSection(c), whiteBalanceSection(c)],
      DeckPage.color => [colorSection(c)],
      DeckPage.grade => [gradeSection(c)],
      DeckPage.hdr => [?hdrHighlightsSection(c)],
      DeckPage.select => selectivePanel(c),
      DeckPage.crop => cropPanel(c),
    };

/// The tools' pages keep their sections' titles: a tool has many, on one page.
bool flatPage(DeckPage page) => page != DeckPage.select && page != DeckPage.crop;
