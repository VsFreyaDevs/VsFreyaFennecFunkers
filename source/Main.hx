package;

import flixel.FlxG;
import flixel.FlxGame;
import flixel.FlxState;
import flixel.tweens.FlxTween;
import funkin.Preferences;
#if desktop
import funkin.audio.ALSoftConfig; // Just to make sure DCE doesn't remove this, since it's not directly referenced anywhere else.
#end
import funkin.util.logging.CrashHandler;
import funkin.ui.debug.MemoryCounter;
import funkin.FunkinGame;
import funkin.save.Save;
import haxe.ui.Toolkit;
import openfl.display.FPS;
import openfl.display.Sprite;
import openfl.events.Event;
import openfl.Lib;
import openfl.media.Video;
import openfl.net.NetStream;
import funkin.audio.AudioSwitchFix;

// Adds support for FeralGamemode on Linux
#if (linux && !DISABLE_GAMEMODE)
@:cppInclude('./external/gamemode_client.h')
@:cppFileCode('
	#define GAMEMODE_AUTO
')
#end

/**
 * The main class which initializes HaxeFlixel and starts the game in its initial state.
 */
class Main extends Sprite
{
  public static var instance:Main;

  var game:FunkinGame;

  var gameWidth:Int = 1280; // Width of the game in pixels (might be less / more in actual pixels depending on your zoom).
  var gameHeight:Int = 720; // Height of the game in pixels (might be less / more in actual pixels depending on your zoom).
  var initialState:Class<FlxState> = funkin.InitState; // The FlxState the game starts with.
  var zoom:Float = -1; // If -1, zoom is automatically calculated to fit the window dimensions.
  /*
    #if (web || CHEEMS || mobile)
    var framerate:Int = 60; // How many frames per second the game should run at.
    #else
    var framerate:Int = 144; // How many frames per second the game should run at.
    #end
   */
  var skipSplash:Bool = true; // Whether to skip the flixel splash screen that appears in release mode.
  var startFullscreen:Bool = false; // Whether to start the game in fullscreen on desktop targets

  // You can pretty much ignore everything from here on - your code should go in your states.
  #if !web
  public static var lightMode:Bool = Sys.args().contains("-lightui");
  #else
  public static var lightMode:Bool = false;
  #end

  // You can pretty much ignore everything from here on - your code should go in your states.
  // [ * -- INTERNAL VARIABLES - PLS DONT TOUCH THEM! -- * ] //
  @:dox(hide)
  public static var audioDisconnected:Bool = false; // Used for checking for audio device errors.

  public static function main():Void
  {
    // Set the current working directory for Android and iOS devices
    #if android
    // For Android we determine the appropriate directory based on Android version
    Sys.setCwd(haxe.io.Path.addTrailingSlash(android.os.Build.VERSION.SDK_INT > 30 ? android.content.Context.getObbDir() : // Use Obb directory for Android SDK version > 30
      android.content.Context.getExternalFilesDir() // Use External Files directory for Android SDK version < 30
    ));
    #elseif ios
    Sys.setCwd(haxe.io.Path.addTrailingSlash(lime.system.System.documentsDirectory)); // For iOS we use documents directory and this is only way we can do.
    #end

    // We need to make the crash handler LITERALLY FIRST so nothing EVER gets past it.
    CrashHandler.initialize();
    CrashHandler.queryStatus();

    funkin.util.WindowUtil.enableVisualStyles();

    Lib.current.addChild(new Main());
  }

  public function new()
  {
    super();

    instance = this;

    #if windows
    @:functionCode("
			#include <windows.h>
      #include <winuser.h>
			setProcessDPIAware() // Allows for more crispy visuals.
		")
    #end

    // Initialize custom logging.
    haxe.Log.trace = funkin.util.logging.AnsiTrace.trace;
    funkin.util.logging.AnsiTrace.traceBF();

    #if mobile
    // funkin.mobile.util.StorageUtil.copyNecessaryFiles(['mp4' => 'assets/videos']);
    #end

    // Load mods to override assets.
    // TODO: Replace with loadEnabledMods() once the user can configure the mod list.
    funkin.modding.PolymodHandler.loadAllMods();

    AudioSwitchFix.init();

    stage != null ? init() : addEventListener(Event.ADDED_TO_STAGE, init);
  }

  function init(?event:Event):Void
  {
    #if web
    // set this variable (which is a function) from the lime version at lime/_internal/backend/html5/HTML5Application.hx
    // The framerate cap will more thoroughly initialize via Preferences in InitState.hx
    funkin.Preferences.lockedFramerateFunction = untyped js.Syntax.code("window.requestAnimationFrame");
    #end

    if (hasEventListener(Event.ADDED_TO_STAGE)) removeEventListener(Event.ADDED_TO_STAGE, init);

    setupGame();
  }

  var video:Video;
  var netStream:NetStream;
  var overlay:Sprite;

  /**
   * A frame & RAM counter displayed at the top left.
   */
  public static var fpsCounter:MemoryCounter;

  function setupGame():Void
  {
    initHaxeUI();

    // addChild gets called by the user settings code.
    fpsCounter = new MemoryCounter(10, 3, 0xFFFFFF);

    // George recommends binding the save before FunkinGame is created.
    Save.load();

    #if mobile
    FlxG.signals.gameResized.add(resizeGame);

    // Use device's refresh rate.
    var coolRate = Preferences.framerate;
    coolRate = Lib.application.window.displayMode.refreshRate;

    if (coolRate < 60) coolRate = 60;
    #end

    game = new FunkinGame(gameWidth, gameHeight, initialState, Preferences.framerate, Preferences.framerate, skipSplash, startFullscreen);

    openfl.Lib.current.stage.align = "tl";
    openfl.Lib.current.stage.scaleMode = openfl.display.StageScaleMode.NO_SCALE;

    // flixel.FlxG.game._customSoundTray wants just the class, it calls new from
    // create() in there, which gets called when it's added to stage
    // which is why it needs to be added before addChild(game) here
    @:privateAccess
    game._customSoundTray = funkin.ui.options.FunkinSoundTray;

    addChild(game);

    #if FEATURE_DEBUG_FUNCTIONS
    game.debugger.interaction.addTool(new funkin.util.TrackerToolButtonUtil());
    #end

    /*
      #if mobile
      flixel.FlxG.game.addChild(fpsCounter);
      #else
      addChild(fpsCounter);
      #end
     */

    #if hxcpp_debug_server
    trace('hxcpp_debug_server is enabled! You can now connect to the game with a debugger.');
    #else
    trace('hxcpp_debug_server is disabled! This build does not support debugging.');
    #end
  }

  // kinda like Sanic's Psych Engine 0.3.2h fork
  public static function tweenFPS(visible:Bool = true, duration:Float = 1.5)
  {
    if (Preferences.debugDisplay && fpsCounter != null) if (visible) FlxTween.tween(fpsCounter, {alpha: 1}, duration);
    else
      FlxTween.tween(fpsCounter, {alpha: 0}, duration);
  }

  function initHaxeUI():Void
  {
    // Calling this before any HaxeUI components get used is important:
    // - It initializes the theme styles.
    // - It scans the class path and registers any HaxeUI components.
    Toolkit.init();
    if (lightMode) Toolkit.theme = 'light'; // embrace cringe
    else
      Toolkit.theme = 'dark'; // don't be cringe
    Toolkit.autoScale = false;
    // Don't focus on UI elements when they first appear.
    haxe.ui.focus.FocusManager.instance.autoFocus = false;
    funkin.input.Cursor.registerHaxeUICursors();
    haxe.ui.tooltips.ToolTipManager.defaultDelay = 175;
  }

  function resizeGame(width:Int, height:Int):Void
  {
    // Calling this so it gets scaled based on the resolution of the game and device's resolution.
    final scale:Float = Math.min(flixel.FlxG.stage.stageWidth / flixel.FlxG.width, flixel.FlxG.stage.stageHeight / flixel.FlxG.height);

    if (fpsCounter != null) fpsCounter.scaleX = fpsCounter.scaleY = (scale > 1 ? scale : 1);
  }

  #if windows
  private override function __update(transformOnly:Bool, updateChildren:Bool):Void
  {
    super.__update(transformOnly, updateChildren);
    if (Main.audioDisconnected) AudioSwitchFix.reloadAudioDevice();
  }
  #end
}
