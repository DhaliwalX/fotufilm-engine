enum MotionTemplateSkeleton {
    static let text = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE ozxmlscene>
<ozml version="5.13">
  <displayversion>5.6.3.1</displayversion>

  <factory id="1" uuid="46c844a813d311d8a438000a95af9f7e">
    <description>Channel</description>
    <manufacturer>Apple</manufacturer>
    <version>1</version>
  </factory>
  <factory id="2" uuid="65cb4dc9d4504fa281921f5f751fba06">
    <description>Widget</description>
    <manufacturer>Apple</manufacturer>
    <version>1</version>
  </factory>
  <factory id="3" uuid="66fc0d6af6a911d6a7a7000393670732">
    <description>Image</description>
    <manufacturer>Apple</manufacturer>
    <version>1</version>
  </factory>
  <factory id="4" uuid="7d468273c013498e9806a0d7bc32fddf">
    <description>Project</description>
    <manufacturer>Apple</manufacturer>
    <version>1</version>
  </factory>
  <factory id="5" uuid="dbca752470fd11d7980100039389b702">
    <description>Channel</description>
    <manufacturer>Apple</manufacturer>
    <version>1</version>
  </factory>
  <factory id="6" uuid="deca4859b16011d7a12d0003936f6f92">
    <description>ProPlugin Filter</description>
    <manufacturer>Apple</manufacturer>
    <version>1</version>
  </factory>

  <template><flags>1</flags></template>
  <build></build>
  <description>Fotufilm</description>

  <scene>
    <sceneSettings>
      <width>1920</width>
      <height>1080</height>
      <duration>300</duration>
      <shouldOverrideFCDuration>0</shouldOverrideFCDuration>
      <frameRate>30</frameRate>
      <NTSC>1</NTSC>
      <pixelAspectRatio>1</pixelAspectRatio>
      <workingGamut>1</workingGamut>
      <viewGamut>-1</viewGamut>
      <optimizeForDisplay>0</optimizeForDisplay>
      <backgroundColor red="0" green="0" blue="0" alpha="1"/>
      <audioChannels>2</audioChannels>
      <audioBitsPerSample>32</audioBitsPerSample>
      <fieldRenderingMode>0</fieldRenderingMode>
      <motionBlurSamples>8</motionBlurSamples>
      <motionBlurDuration>1</motionBlurDuration>
      <sharpScaling>0</sharpScaling>
      <startTimecode>0</startTimecode>
      <backgroundMode>0</backgroundMode>
      <reflectionRecursionLimit>2</reflectionRecursionLimit>
      <glyphOSCMode>0</glyphOSCMode>
      <animateFlag>0</animateFlag>
      <parameterColorSpaceID>3</parameterColorSpaceID>
      <savePreviewMovie>0</savePreviewMovie>
      <Object3DEnvironments>100</Object3DEnvironments>
      <DRTSupport>1</DRTSupport>
    </sceneSettings>
    <publishSettings>
      <version>2</version>
@PUBLISH@
    </publishSettings>

    <timeRange offset="0 1 1 0" duration="1201200 120000 1 0"/>
    <playRange offset="0 1 1 0" duration="1201200 120000 1 0"/>
    <flags>1</flags>
    <audioTracks>0</audioTracks>
    <timemarkerset/>
    <guideset/>
    <curvesets selected="1"/>

    <scenenode name="Project" id="9000001" factoryID="4" version="5">
      <scenenode name="Widget" id="9000002" factoryID="2" version="5">
        <flags>0</flags>
        <timing in="0 1 1 0" out="-4004 120000 1 0" offset="0 1 1 0"/>
        <foldFlags>0</foldFlags>
        <baseFlags>16</baseFlags>
        <parameter name="Properties" id="1" flags="8589938704"/>
        <parameter name="Object" id="2" flags="8589938704">
          <parameter name="Options" id="103" flags="8589938688"/>
          <parameter name="Hidden" id="102" flags="8589934608" default="0" value="1"/>
          <parameter name="Snapshots" id="101" flags="8589938706"/>
          <parameter name="Widget" id="100" flags="8589934608"
                     default="1.7777777777777777" value="1.7777777777777777"/>
        </parameter>
      </scenenode>
      <flags>0</flags>
      <timing in="0 1 1 0" out="-4004 120000 1 0" offset="0 1 1 0"/>
      <foldFlags>0</foldFlags>
      <baseFlags>16</baseFlags>
      <parameter name="Properties" id="1" flags="8589938704"/>
      <parameter name="Object" id="2" flags="8589938704"/>
    </scenenode>

    <layer name="Group" id="9000003">
      <scenenode name="Effect Source" id="9000004" factoryID="3" version="5">
        <validTracks>1</validTracks>
        <aspectRatio>1</aspectRatio>
        <flags>0</flags>
        <timing in="0 1 1 0" out="1197196 120000 1 0" offset="0 1 1 0"/>
        <foldFlags>16384</foldFlags>
        <baseFlags>524304</baseFlags>
        <parameter name="Properties" id="1" flags="8589938704">
          <parameter name="Media" id="324" flags="8589938704">
            <foldFlags>4</foldFlags>
            <parameter name="Source Media" id="300" flags="81621221392"
                       default="9002001" value="9002001"/>
            <parameter name="Source Media" id="325" flags="8590000146"/>
          </parameter>
          <parameter name="Page Number" id="301" flags="8589934610" default="1" value="1"/>
          <parameter name="Retime Value" id="304" flags="8590066066" default="1" value="1"/>
          <parameter name="Retime Value Cache" id="319" flags="8590065810"
                     default="1" value="1"/>
        </parameter>
        <parameter name="Object" id="2" flags="8589938704">
          <parameter name="Drop Zone" id="311" flags="8589934738" default="0" value="1"/>
          <parameter name="Type" id="321" flags="8590000146" default="0" value="3"/>
          <parameter name="Width" id="313" flags="8589934610" default="1" value="1920"/>
          <parameter name="Height" id="314" flags="8589934610" default="1" value="1080"/>
        </parameter>
        <filter name="Fotufilm" id="9001001" factoryID="6"
                pluginUUID="C4D9D06C-A2A7-48B4-830B-9AE81B970140"
                pluginVersion="1" pluginName="FotufilmEffect" pluginDynamicParams="0">
          <timing in="0 1 1 0" out="1197196 120000 1 0" offset="0 1 1 0"/>
          <baseFlags>8589934608</baseFlags>
@FILTER@
        </filter>
      </scenenode>

      <aspectRatio>1</aspectRatio>
      <flags>0</flags>
      <timing in="0 1 1 0" out="1197196 120000 1 0" offset="0 1 1 0"/>
      <foldFlags>0</foldFlags>
      <baseFlags>524304</baseFlags>
      <parameter name="Properties" id="1" flags="8589938704"/>
      <parameter name="Object" id="2" flags="8589938704">
        <parameter name="Fixed Width" id="302" flags="12884901908"
                   default="1920" value="1920"/>
        <parameter name="Fixed Height" id="303" flags="12884901908"
                   default="1080" value="1080"/>
        <parameter name="Flatten" id="311" flags="8589934610" default="0" value="0"/>
        <parameter name="Layer Order" id="305" flags="8589934610" default="0" value="0"/>
        <parameter name="Aperture Width" id="312" flags="12884901906"
                   default="1920" value="1920"/>
        <parameter name="Aperture Height" id="313" flags="12884901906"
                   default="1080" value="1080"/>
      </parameter>
    </layer>

    <footage name="Media Layer" id="9000005">
      <clip name="Drop Zone" id="9002001">
        <pathURL>Drop Zone.tiff</pathURL>
        <missingWidth>1920</missingWidth>
        <missingHeight>1080</missingHeight>
        <missingDuration>0.033333333333333333</missingDuration>
        <creationDuration>1</creationDuration>
        <mediaID></mediaID>
        <flags>0</flags>
        <timing in="0 1 1 0" out="0 120000 1 0" offset="0 1 1 0"/>
        <foldFlags>0</foldFlags>
        <baseFlags>524304</baseFlags>
        <parameter name="Properties" id="1" flags="8589938704"/>
        <parameter name="Object" id="2" flags="8589938704">
          <parameter name="Pixel Aspect Ratio" id="104" flags="12884901888"
                     default="1" value="1"/>
          <parameter name="Frame Rate" id="107" flags="8589934592" default="0" value="30"/>
          <parameter name="Fixed Width" id="114" flags="12884901888"
                     default="1920" value="1920"/>
          <parameter name="Fixed Height" id="115" flags="12884901888"
                     default="1080" value="1080"/>
          <parameter name="Use Background Color" id="116" flags="8589934594"
                     default="0" value="0"/>
          <parameter name="Missing Is Still" id="128" flags="8589934610"
                     default="0" value="1"/>
        </parameter>
      </clip>
      <flags>0</flags>
      <timing in="0 1 1 0" out="-4004 120000 1 0" offset="0 1 1 0"/>
      <foldFlags>0</foldFlags>
      <baseFlags>524304</baseFlags>
      <parameter name="Properties" id="1" flags="8589938704"/>
      <parameter name="Object" id="2" flags="8589938704"/>
    </footage>
  </scene>
</ozml>
"""
}
