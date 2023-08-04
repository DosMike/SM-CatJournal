#if defined __REBANE_STOCK_PRECACHE_H__
#endinput
#endif
#define __REBANE_STOCK_PRECACHE_H__

static bool _strEnds(const char[] haystack, const char[] needle, bool caseSensitive=true) {
	int lenh = strlen(haystack);
	int lenn = strlen(needle);
	if (lenh < lenn) return false;
	int offset = lenh - lenn;
	return StrEqual(haystack[offset], needle, caseSensitive);
}
static void _stripExt(const char[] name, int after=0) {
	//strrpos
	if (after < 0) return;
	int at = strlen(name)-1-after;
	while (at >= 0 && name[at] != '.') at -= 1;
	if (at < 0) return;
	//cut
	name[at] = '\0';
}

stock void AutoPrecacheModel(const char[] name, bool preload=false) {
	PrecacheModel(name, preload);
	// this requires the assets we are using to NOT be packed in VPKs
	// while still allowing assets to be managed in /custom/mod/ directories.
	// particle systems use PrecacheModel as well. If someone accidentally passes
	// a particle system name, we dont want to have to check file existence.
	bool needToDownload = (_strEnds(name, ".mdl", false)) && (FileExists(name, false) || FileExists(name, true, "custom_mod"));
	if (needToDownload) {
		AddFileToDownloadsTable(name);
		char filename[PLATFORM_MAX_PATH];
		strcopy(filename, sizeof(filename), name);
		
		_stripExt(filename);
		StrCat(filename, sizeof(filename), ".phy");
		AddFileToDownloadsTable(filename);
		
		_stripExt(filename);
		StrCat(filename, sizeof(filename), ".vvd");
		if (FileExists(filename, true, "mod")) {
			AddFileToDownloadsTable(filename);
		}
		
		_stripExt(filename);
		StrCat(filename, sizeof(filename), ".sw.vtx");
		if (FileExists(filename, true, "mod")) {
			AddFileToDownloadsTable(filename);
		}
		
		_stripExt(filename,4);
		StrCat(filename, sizeof(filename), ".dx80.vtx");
		if (FileExists(filename, true, "mod")) {
			AddFileToDownloadsTable(filename);
		}
		
		_stripExt(filename,4);
		StrCat(filename, sizeof(filename), ".dx90.vtx");
		if (FileExists(filename, true, "mod")) {
			AddFileToDownloadsTable(filename);
		}
	}
}

stock void AutoPrecacheSound(const char[] name, bool preload=false) {
	char buffer[PLATFORM_MAX_PATH];
	if (StrContains(name, "sound/")==0) {
		strcopy(buffer, sizeof(buffer), name);
	}
	else {
		buffer = "sound/";
		strcopy(buffer[6], sizeof(buffer)-6, name);
	}
	
	PrecacheSound(buffer[6], preload);
	// this requires the assets we are using to NOT be packed in VPKs
	// while still allowing assets to be managed in /custom/mod/ directories.
	bool needToDownload = (FileExists(buffer, false) || FileExists(buffer, true, "custom_mod"));
	if (needToDownload) {
		AddFileToDownloadsTable(buffer);
	}
}

// remove sound/ prefix if it exists
// this make the path playable (if it exists)
stock void MakeSoundPathCanonical(char[] name) {
	if (StrContains(name, "sound/")==0) {
		for (int i=6; i<=strlen(name); i++)
			name[i-6] = name[i];
	}
}
