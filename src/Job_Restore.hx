package;

import djNode.app.FFmpegAudio;
import djNode.task.FakeTask;
import djNode.task.Job;
import djNode.task.Task.Qtask;
import djNode.task.Task_ExtractFile;
import djNode.tools.CDInfo;
import djNode.tools.FileTool;
import djNode.tools.LOG;
import js.node.Fs;
import js.node.Path;
import CDC;


/** 
 * Create a job that will Restore a file.
 * ---------------------------------------------
 * This job gets running parameters from the 
 * taskData object which is set in the CDC class
 * Also might use some CDC static vars.
 * ---------------------------------------------
 * onFail emits these codes : ( feature still in development and not used!! )
 * 		user 		: user error ?
 * 		IO 			: write access problem, not enough free space?>
 * 		corrupt 	: ARC is corrupt!
 **/
class Job_Restore extends Job
{
	
	static var DIR_POSTFIX:String = " (restored)";
	
	// Pointer to sharedData, I am doing this to get intellisense 
	var par:CDCRunParameters;
	
	
	// -- PRE: par must be set
	function processOutputFolder()
	{
	
		if (par.outputDir == null) { // null or other dir
			par.outputDir = par.inputDir;
		}
			
		if (CDC.flag_res_to_folders)
		{
			 par.outputDir = Path.join(par.outputDir, Path.parse(par.input).name + DIR_POSTFIX);
			
			// If already exists, then ERROR
			if (FileTool.pathExists(par.outputDir) && !CDC.flag_overwrite) {
				throw 'Output Dir ${par.outputDir} already exists\n Use -w to force overwrite, or delete manually to avoid errors.';
			}
		
			// Try to create the output dir
			try {
				FileTool.createRecursiveDir(par.outputDir);
			}catch (e:Dynamic) {
				throw 'Cannot create ${par.outputDir}.\n Do you have write access?';
			}
			
		}else
		{
			// Just check if the output is writable
			CDC.isWritable(par.outputDir);
		}
		
		LOG.log(" - Setting Output dir to " + par.outputDir);
		
	}//---------------------------------------------------;
	

	//====================================================;
	override public function start():Void 
	{
		// Easy access, intellisense
		par = cast sharedData;
		
		#if debug 
		if (CDC.simulatedRun) {
		 addQueue_simulate(); super.start(); return;
		}
		#end
		
		add(new Task_CheckFFMPEG());
		
		// REMEMBER : Tasks staring with "-" DO NOT REPORT STATUS!!!!
		// -- Precheck
		add(new Qtask("-prerun", function(t:Qtask) {
			
			if (!FileTool.pathExists(par.input)) {
				t._fail('File "${par.input}" does not exist');
				return;
			}
						
			// NOTE: File existence is checked by FileExtractor_Task
			if (FileTool.getFileExt(par.input) != CDC.CDCRUSH_EXTENSION) {
				t._fail('Input file is NOT a [.${CDC.CDCRUSH_EXTENSION}] file', 'user');
				return;
			}
			
			// -- Generate output Folder
			processOutputFolder();
			
			// Try to create the temp dir, which is input filename specific
			if (!CDC.createTempDir(par)) {
				t._fail('Could not create tempdir at "${par.tempDir}"' , "IO"); 
				return;
			}
			
			// Get ARC filesize
			par.sizeBefore = Std.int(Fs.statSync(par.input).size);
		
			// Send this object to the next Task, which should be TASK_EXTRACT_FILE
			t._dataSend( { 
				input:par.input, 
				output:par.tempDir 
				});
			
			t._complete();
		}));
		
		// Predefined task that will extract a file to a dir
		// The parameters are going to be fetched from the previous task!
		add(new Task_ExtractFile());
		
		// --
		add(new Qtask("-loadcdinfo", function(t:Qtask) {
			par.cd = new CDInfo();
			try{
				par.cd.loadSettingsFile(Path.join(par.tempDir, CDC.CDCRUSH_SETTINGS));
			}catch (e:String) {
				t._fail(e, 'corrupt');
			}
			
			// Set generated files info now, They don't exist yet
			// Imagepath is for single CUE.BIN files
			par.imagePath = Path.join(par.outputDir, par.cd.TITLE + ".bin");
			par.cuePath = Path.join(par.outputDir, par.cd.TITLE + ".cue");
			
			// Add as many tasks as there are tracks.
			var c = par.cd.tracks_total;
			while (--c >= 0) {
				this.addNext(new Task_RestoreTrack(par.cd.tracks[c]));
			}
			
			t._complete();
			
		}));

		
		// -- Move or Join depending on multitrack ::

		add(new Qtask("-loadcdinfo", function(t:Qtask) {
			
			// par.imagePath must be set
			if (par.cd.isMultiImage && !CDC.flag_single_restore) {
				addNext(new Task_MoveFiles());
			}else {
				addNext(new Task_JoinTracks());
			}
			t._complete();
			
		}));

		
		// -- Image is ready at output folder
		//    .Create the CUE file and delete leftovers
		add(new Qtask("-finalize", function(t:Qtask) {
			
			par.sizeAfter = par.cd.total_size;
			
			// EXPERIMENTAL ::
			// Fix the track data if single restore
			if (CDC.flag_single_restore)
			{
				par.cd.convertMultiToSingle();
			}// --
			
			LOG.log('Creating CUE at ${par.cuePath}');
			par.cd.saveAs_Cue(par.cuePath, "GENERATED BY CDCRUSH " + CDC.PROGRAM_VERSION);
			
			LOG.log('Clearing temp dir');
			// Original track Files are already moved
			Fs.unlinkSync(Path.join(par.tempDir, CDC.CDCRUSH_SETTINGS));
			Fs.rmdirSync(par.tempDir);
			
			t._complete();
		}));
		
		super.start();
	}//---------------------------------------------------;
	
	
	//====================================================;
	// SIMULATE A RUN TO CHECK THE PROGRESS INDICATORS
	//====================================================;
	#if debug function addQueue_simulate()
	{
		
		var gamename = Path.parse(Path.basename(par.input)).name;
		var gamedir = Path.dirname(par.input);
			
		par.sizeBefore = 32000134;
		par.sizeAfter = 512000000; 
		par.imagePath = gamedir + gamename + ".bin";
		par.cuePath = gamedir + gamename + ".cue";
			
		add(new FakeTask("Extracting", "progress", 0.5));
		add(new FakeTask("Restoring track 1", "progress", 0.3));
		add(new FakeTask("Restoring track 2", "progress", 0.3));
		add(new FakeTask("Restoring track 3", "progress", 0.3));
		add(new FakeTask("Joining Tracks", "steps", 0.1));
	}//---------------------------------------------------;
	#end
	
}// --