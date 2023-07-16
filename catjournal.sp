#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <clientprefs>
#include "playerpicker.inc"
#include "mincolor.inc"
#include "particles.inc"
#include "precache.inc"

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "23w28a"

char g_catThingName[32];
char g_catChatPrefix[32];
char g_catCommandName[3][32];
#define CCMD_STATS 0
#define CCMD_RANKUP 1
#define CCMD_BONUS 2

char g_catLevelUpPath[PLATFORM_MAX_PATH]; //for levels
char g_catPowerUpPath[4][PLATFORM_MAX_PATH]; // you can power up 4 times, 1->5
ArrayList g_catAssetPaths;
ArrayList g_catModelPaths;
ArrayList g_catMeowPaths;

char g_catLevels[21][32];

#define NORMAL_GLOW "utaunt_twinkling_goldsilver_glow01"
//#define BONUS_GLOW "burningplayer_redglow"
//#define BONUS_GLOW "ghost_pumpkin_blueglow"
#define BONUS_GLOW "utaunt_twinkling_rgb_glow01"

#define DROP_INACTIVE_TIME 0.75
#define DROP_INACTIVE_TIME_BONUS 1.5
#define DROP_BLINK_TIME 20.0
#define DROP_DESPAWN_TIME 30.0
#define DROP_PICKUP_RANGE 64.0

enum JournalEntry {
	cjCaptured=0,
	cjCreated=1,
	cjObjective=2,
	cjBonus=3,
	cjRecovered=4,
	cjTeamCaptured=5
}
int g_rankupXP;
int g_journalXP[6];

char g_powerColors[5][8]={
	"\x075E98D9",
	"\x074B69FF",
	"\x078847FF",
	"\x07D32CE6",
	"\x07EB4B4B",
};

Cookie g_cookieMuted;
Cookie g_cookieMeowdic;

Database g_catbase;
bool g_isMySQL;

enum struct CatData {
	int xp;
	int journal[6];
	int power;
	int streak;
	int loadState;
	bool deathHandled;
	bool muted;
	bool meowdic;
	
	int level() {
		int lvl = this.xp/g_rankupXP - this.power*20;
		if (lvl < 0) lvl=0; else if (lvl > 20) lvl=20;
		return lvl;
	}
	void collect(int cats, JournalEntry entry, int self) {
		int levelPre = this.level();
		this.journal[entry] += cats;
		this.xp += (cats*g_journalXP[entry]);
		int levelPost = this.level();
		if (levelPre != levelPost) {
			CNextColorSource(self);
			CPrintToChatAll("\x03%N\x01's %s Journal has reached a new rank: \x07FFD700%s\x01", self, g_catThingName, g_catLevels[levelPost]);
			EmitSoundToAll(g_catLevelUpPath);
		}
	}
	bool addStreak(int streak) {
		int streakModPre = this.streak/10;
		this.streak+=streak;
		int streakModPost = this.streak/10;
		return streakModPre != streakModPost;
	}
	void reset() {
		this.xp = 0;
		this.journal[cjCaptured] = 0;
		this.journal[cjCreated] = 0;
		this.journal[cjObjective] = 0;
		this.journal[cjBonus] = 0;
		this.journal[cjRecovered] = 0;
		this.journal[cjTeamCaptured] = 0;
		this.power = 0;
		this.streak = 0;
		this.deathHandled = false;
		this.muted = false;
		this.meowdic = false;
	}
}
CatData clientCat[MAXPLAYERS+1];

enum KibbyFlags {
	kfNONE = 0,
	kfObjective = 1,
	kfBonus = 2,
	kfInactive = 4,
};
enum struct KibbyData {
	int entRef;
	int owner;
	int team;
	KibbyFlags flags;
	float created;
	
	// ret 0 unchanged : 1 changed : -1 stale
	int RemoveThink() {
		float age = GetGameTime()-this.created;
		int ent = EntRefToEntIndex(this.entRef);
		if (ent == INVALID_ENT_REFERENCE) return -1;
		
		if (age >= DROP_DESPAWN_TIME && !hasMoveParent(ent)) {
			KillEntityAndParticleEffects(ent);
			return -1;
		} else if (age >= DROP_BLINK_TIME) {
			SetEntityRenderMode(ent, RENDER_TRANSALPHA);
			SetEntityRenderColor(ent, .a= (RoundToFloor(age*2)%2)*155+100 );
		} else if ((this.flags & kfInactive) == kfInactive &&
			       age >= ((this.flags&kfBonus) ? DROP_INACTIVE_TIME_BONUS : DROP_INACTIVE_TIME)) {
			this.flags = this.flags & (~kfInactive);
			return 1;
		}
		return 0;
	}
	void From(int kibby, int owner, KibbyFlags flags) {
		this.entRef = EntIndexToEntRef(kibby);
		this.owner = (owner ? GetClientUserId(owner) : 0);
		this.team = (owner ? GetClientTeam(owner) : 0);
		this.flags = flags|kfInactive;
		this.created = GetGameTime();
	}
}
ArrayList g_kibbyData;

public Plugin myinfo = {
	name = "[TF2] Cat Journal",
	author = "reBane",
	description = "meow",
	version = PLUGIN_VERSION,
	url = "N/A"
}

public void OnPluginStart() {
	g_catAssetPaths = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	g_catModelPaths = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	g_catMeowPaths = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	char filename[PLATFORM_MAX_PATH];
	char dbname[20]="";
	KeyValues config = new KeyValues("CatJournal");
	if (!config.ImportFromFile("cfg/sourcemod/catconfig.cfg")) {
		SetFailState("Could not find cat config!");
	}
	
	config.GetString("database", dbname, sizeof(dbname), "");
	config.GetString("thing_name", g_catThingName, sizeof(g_catThingName), "Cat");
	config.GetString("chat_prefix", g_catChatPrefix, sizeof(g_catChatPrefix), "[CatJournal] ");
	config.GetString("command_journal", g_catCommandName[CCMD_STATS], sizeof(g_catCommandName[]), "sm_catjournal");
	config.GetString("command_rankup", g_catCommandName[CCMD_RANKUP], sizeof(g_catCommandName[]), "sm_catup");
	config.GetString("command_spawnbonus", g_catCommandName[CCMD_BONUS], sizeof(g_catCommandName[]), "sm_bonuscats");
	if (dbname[0]==0)
		SetFailState("Database name missing");
	if (g_catThingName[0]==0)
		SetFailState("Empty thing names are not valid");
	if (g_catCommandName[CCMD_STATS][0] == 0 || g_catCommandName[CCMD_RANKUP][0] == 0 || g_catCommandName[CCMD_BONUS][0] == 0)
		SetFailState("Empty command names are not premitted");
	
	char tmp[32];
	
	if (config.JumpToKey("assets")) {
		if (config.GotoFirstSubKey(false)) {
			do {
				if (!config.GetSectionName(tmp, sizeof(tmp))) break;
				config.GetString(NULL_STRING, filename, sizeof(filename));
				if (filename[0]==0) break;
				if (StrEqual(tmp, "download")) {
					g_catAssetPaths.PushString(filename);
				} else if (StrEqual(tmp, "sound_drop")) {
					MakeSoundPathCanonical(filename);
					g_catMeowPaths.PushString(filename);
				} else if (StrEqual(tmp, "model")) {
					g_catModelPaths.PushString(filename);
				} else if (StrEqual(tmp, "sound_levelup")) {
					MakeSoundPathCanonical(filename);
					strcopy(g_catLevelUpPath, sizeof(g_catLevelUpPath), filename);
				} else if (StrContains(tmp, "sound_powerup")==0) {
					int i = (tmp[13]-'1');
					if (0 <= i < 4) {
						MakeSoundPathCanonical(filename);
						strcopy(g_catPowerUpPath[i], sizeof(g_catPowerUpPath[]), filename);
					}
				}
			} while (config.GotoNextKey(false));
			config.GoBack();
		}
		config.GoBack();
	} else SetFailState("Config is missing assets section");
	
	if (g_catAssetPaths.Length == 0)
		PrintToServer("[CatJournal Loader] WARNING: Config has no download entries");
	if (g_catModelPaths.Length == 0)
		SetFailState("Config has no model entries");
	if (g_catMeowPaths.Length == 0)
		SetFailState("Config has no sound_drop entries");
	if (g_catLevelUpPath[0]==0)
		SetFailState("Config is missing sound_levelup sound");
	for (int i=0; i<4; i++)
		if (g_catPowerUpPath[i][0]==0)
			SetFailState("Config is missing sound_powerup%i sound", i+1);
	
	if (config.JumpToKey("ranks")) {
		g_catLevels[0]="Meow";//dummy
		for (int i=1;i<=20;i++) {
			FormatEx(tmp, sizeof(tmp), "rank%i", i);
			config.GetString(tmp, g_catLevels[i], sizeof(g_catLevels[]));
			if (g_catLevels[i][0]==0) SetFailState("Config is missing %s name", tmp);
		}
		config.GoBack();
	} else SetFailState("Config is missing ranks section");
	
	if (config.JumpToKey("xp")) {
		g_rankupXP = config.GetNum("rankup", 5000);
		g_journalXP[cjCaptured] = config.GetNum("capture", 3);
		g_journalXP[cjCreated] = config.GetNum("create", 3);
		g_journalXP[cjObjective] = config.GetNum("objective", 3);
		g_journalXP[cjBonus] = config.GetNum("bonus", 50);
		g_journalXP[cjRecovered] = config.GetNum("recover", 1);
		g_journalXP[cjTeamCaptured] = config.GetNum("teamcapture", 3);
	} else SetFailState("Config is missing xp section");
	
	delete config;
	
	Database.Connect(OnDBConnected, dbname);
	
	LoadTranslations("common.phrases.txt");
	
	char buffer[128];
	FormatEx(buffer, sizeof(buffer), "Usage: %s [player] - print %s Journal info", g_catCommandName[CCMD_STATS], g_catThingName);
	RegConsoleCmd(g_catCommandName[CCMD_STATS], CmdCatJournal, buffer);
	FormatEx(buffer, sizeof(buffer), "Usage: %s - rank up your %s Journal", g_catCommandName[CCMD_RANKUP], g_catThingName);
	RegConsoleCmd(g_catCommandName[CCMD_RANKUP], CmdCatUp, buffer);
	FormatEx(buffer, sizeof(buffer), "Usage: %s <amount> - spawn Bonus %s", g_catCommandName[CCMD_BONUS], g_catThingName);
	RegAdminCmd(g_catCommandName[CCMD_BONUS], CmdCatBonus, ADMFLAG_GENERIC, buffer);
	
	HookEvent("player_death", OnClientDeath);
	//pl koth cp
	HookEvent("teamplay_point_captured", OnObjectivePointCapped);
	//ctf
	HookEvent("teamplay_flag_event", OnObjectiveFlagCapture);
	//pass
	HookEvent("pass_score", OnObjectivePasstimeScore);
	
	AddNormalSoundHook(OnNormalSHook);
	
	g_cookieMuted = new Cookie("catjournal_mute", "Wether the spawn and pickup sounds are muted", CookieAccess_Private);
	g_cookieMeowdic = new Cookie("catjournal_meowdic", "Replace MEDIC! with a Meow!", CookieAccess_Private);
	FormatEx(buffer, sizeof(buffer), "%s Journal", g_catThingName);
	SetCookieMenuItem(OnCookieMenu, 0, buffer);
}

public void OnPluginEnd() {
	for (int cat=g_kibbyData.Length-1; cat >=0; cat--) {
		KibbyData kibby;
		if (!g_kibbyData.GetArray(cat, kibby)) continue;
		int kitty = EntRefToEntIndex(kibby.entRef);
		if (kitty == INVALID_ENT_REFERENCE) continue;
		AcceptEntityInput(kitty, "Kill");
	}
	g_kibbyData.Clear();
}


public Action CmdCatJournal(int client, int args) {
	char pattern[128];
	GetCmdArgString(pattern, sizeof(pattern));
	int targets[1];
	char namebuf[32];
	bool tn_is_ml;
	int results;
	if (args && strlen(pattern)) results = ProcessTargetString(pattern, client, targets, MAXPLAYERS, COMMAND_FILTER_NO_BOTS|COMMAND_FILTER_NO_MULTI, namebuf, sizeof(namebuf), tn_is_ml);
	if (results < 0) {
		ReplyToTargetError(client, results);
	} else if (results == 0) {
		if (!client) ReplyToTargetError(client, results);
		else if (!args) PrintJournal(client, GetClientUserId(client));
		else PickPlayer(client, COMMAND_FILTER_NO_BOTS, PrintJournal, GetClientUserId(client));
	} else {
		PrintJournal(targets[0], GetClientUserId(client));
	}
	return Plugin_Handled;
}
void PrintJournal(int print, int client) {
	if ((client = GetClientOfUserId(client))==0) return; //"admin" is gone
	SetCmdReplySource(client?SM_REPLY_TO_CHAT:SM_REPLY_TO_CONSOLE);
	if (print<=0) { ReplyToTargetError(client, print); return; }
	
	if (!IsClientAuthorized(print) || clientCat[print].loadState!=2) {
		if (clientCat[client].loadState == 0) LoadCats(client);
		ReplyToCommand(client, "%sJournal is not yet loaded", g_catChatPrefix);
		return;
	}
	
	int level = clientCat[print].level();
	char journalName[64];
	if (level==0) FormatEx(journalName, sizeof(journalName), "%s Journal", g_catThingName);
	else FormatEx(journalName, sizeof(journalName), "Level %i %s %s Journal", level, g_catLevels[level], g_catThingName);
	
	//header
	if (print == client) {
		CPrintToChat(client, "%sYour \x07FFD700%s\x01 has \x05%i\x01 XP, "...
		                     "with %s%s Power %i\x01 and your %s Streak is \x05%i\x01.",
					g_catChatPrefix, journalName, clientCat[print].xp, 
					g_powerColors[clientCat[print].power], g_catThingName, clientCat[print].power+1, g_catThingName, clientCat[print].streak);
	} else {
		CPrintToChat(client, "%s\x03%N\x01's \x07FFD700%s\x01 has \x05%i\x01 XP, "...
		                     "with %s%s Power %i\x01. Their %s Streak is \x05%i\x01.",
					g_catChatPrefix, print, journalName, clientCat[print].xp, 
					g_powerColors[clientCat[print].power], g_catThingName, clientCat[print].power+1, g_catThingName, clientCat[print].streak);
	}
	//journal
	CPrintToChat(client, "  :: Captured \x05%i\x01 :: Created \x05%i\x01 :: Objective \x05%i\x01", 
				clientCat[print].journal[cjCaptured], clientCat[print].journal[cjCreated], clientCat[print].journal[cjObjective]);
	CPrintToChat(client, "  :: Bonus \x05%i\x01 :: Recovered \x05%i\x01 :: Team Captured \x05%i\x01", 
				clientCat[print].journal[cjBonus], clientCat[print].journal[cjRecovered], clientCat[print].journal[cjTeamCaptured]);
	//rnak up hint
	if (print == client && clientCat[print].level() == 20)
		CPrintToChat(client, "  :: Your journal is max level - Use \x04/%s\x01 to increase it's power", g_catCommandName[CCMD_RANKUP]);
}

public Action CmdCatUp(int client, int args) {
	if (!IsClientAuthorized(client) || clientCat[client].loadState!=2) {
		if (clientCat[client].loadState == 0) LoadCats(client);
		ReplyToCommand(client, "%s%s Journal is not yet loaded", g_catChatPrefix, g_catThingName);
	} else if (clientCat[client].power >= 4) {
		ReplyToCommand(client, "%sYour %s Journal already has maximum power", g_catChatPrefix, g_catThingName);
	} else if (clientCat[client].level() != 20) {
		ReplyToCommand(client, "%sYour %s Journal is not yet level 20", g_catChatPrefix, g_catThingName);
	} else {
		Menu menu = new Menu(HandleCatUpMenu);
		menu.SetTitle("[ % Journal ]\nYou are about to power up your journal.\n\nNOTE: This will reset your level but\nallow you to increase your %s Power", g_catThingName, g_catThingName);
		menu.AddItem("", "", ITEMDRAW_NOTEXT);
		menu.AddItem("", "", ITEMDRAW_NOTEXT);
		menu.AddItem("", "", ITEMDRAW_NOTEXT);
		menu.AddItem("", "", ITEMDRAW_NOTEXT);
		menu.AddItem("", "", ITEMDRAW_NOTEXT);
		menu.AddItem("", "", ITEMDRAW_NOTEXT);
		menu.AddItem("ok", "Confirm");
		menu.Display(client, 30);
	}
	
	return Plugin_Handled;
}
public int HandleCatUpMenu(Menu menu, MenuAction action, int param1, int param2) {
	if (action == MenuAction_Select) {
		if (clientCat[param1].level() != 20 || clientCat[param1].power >= 4) return 0;
		
		EmitSoundToAll(g_catPowerUpPath[clientCat[param1].power]);
		clientCat[param1].power += 1;
		CNextColorSource(param1);
		CPrintToChatAll("\x03%N\x01's \x07FFD700%s Journal\x01 was upgraded to %s%s Power %i\x01",
				param1, g_catThingName, g_powerColors[clientCat[param1].power], g_catThingName, clientCat[param1].power+1);
		
	} else if (action == MenuAction_End) {
		delete menu;
	}
	return 0;
}


public Action CmdCatBonus(int client, int args) {
	char arg1[32];
	int cats;
	if (!client)
		ReplyToCommand(client, "This command is client only");
	else if (!args || !GetCmdArg(1,arg1,sizeof(arg1)))
		ReplyToCommand(client, "Usage: %s <amount>", g_catCommandName[CCMD_BONUS]);
	else if ((cats=StringToInt(arg1))<=0)
		ReplyToCommand(client, "Amount has to be positive");
	else if (cats>50)
		ReplyToCommand(client, "Try not to crash the server... Limit is 50");
	else {
		float pos[3];
		GetClientEyePosition(client, pos);
		SpawnCats(client, pos, cats, kfBonus);
	}
	return Plugin_Handled;
}



// ===== Generic Event Boilerplate =====

public void OnMapStart() {
	char filename[PLATFORM_MAX_PATH];
	for (int cat;cat<g_catModelPaths.Length;cat+=1) {
		g_catModelPaths.GetString(cat, filename, sizeof(filename));
		AutoPrecacheModel(filename);
	}
	for (int cat;cat<g_catAssetPaths.Length;cat+=1) {
		g_catAssetPaths.GetString(cat, filename, sizeof(filename));
		AddFileToDownloadsTable(filename);
	}
	for (int cat;cat<g_catMeowPaths.Length;cat+=1) {
		g_catMeowPaths.GetString(cat, filename, sizeof(filename));
		AutoPrecacheSound(filename);
	}
	AutoPrecacheSound(g_catLevelUpPath);
	for (int cat;cat<4;cat+=1) {
		AutoPrecacheSound(g_catPowerUpPath[cat]);
	}
	
	PrecacheParticleSystem(NORMAL_GLOW);
	PrecacheParticleSystem(BONUS_GLOW);
	
	if (g_kibbyData == INVALID_HANDLE) 
		g_kibbyData = new ArrayList(sizeof(KibbyData));
	else
		g_kibbyData.Clear();
	CreateTimer(0.2, KibbyThinkTick, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	
	for (int client=1; client<=MaxClients; client+=1) {
		if (IsClientInGame(client)) {
			LoadCats(client);
			OnEntityCreated(client, "player"); //player is precise enough for hooking
		}
	}
}
public void OnMapEnd() {
	for (int client=1;client<=MaxClients;client+=1)
		if (IsClientInGame(client)) SaveCats(client);
}


public void OnClientConnected(int client) {
	clientCat[client].loadState = 0;
	clientCat[client].reset();
}


public void OnClientAuthorized(int client, const char[] auth) {
	LoadCats(client);
}

public void OnClientCookiesCached(int client) {
	clientCat[client].muted = g_cookieMuted.GetInt(client) != 0;
	clientCat[client].meowdic = g_cookieMeowdic.GetInt(client) != 0;
}


public void OnClientDisconnect(int client) {
	SaveCats(client);
	clientCat[client].loadState = 0;
	clientCat[client].reset();
}

// ===== Client Settings =====


public void OnCookieMenu(int client, CookieMenuAction action, any info, char[] buffer, int maxlen) {
	if (action == CookieMenuAction_SelectOption) {
		ShowCatJournalSettingsMenu(client);
	}
}

void ShowCatJournalSettingsMenu(int client) {
	Menu menu = new Menu(HandleCatJournalSettingsMenu);
	
	menu.SetTitle("%s Jounral", g_catThingName);
	if (clientCat[client].muted)
		menu.AddItem("unmute", "Sounds for Pickups [Off]");
	else
		menu.AddItem("mute", "Sounds for Pickups [On]");
	if (clientCat[client].meowdic)
		menu.AddItem("medic", "MEDIC! Replacer [On]");
	else
		menu.AddItem("meowdic", "MEDIC! Replacer [Off]");
	
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int HandleCatJournalSettingsMenu(Menu menu, MenuAction action, int param1, int param2) {
	if (action == MenuAction_Select) {
		char info[32];
		menu.GetItem(param2, info, sizeof(info));
		if (StrEqual("unmute", info)) {
			clientCat[param1].muted = false;
			g_cookieMuted.SetInt(param1, 0);
		} else if (StrEqual("mute", info)) {
			clientCat[param1].muted = true;
			g_cookieMuted.SetInt(param1, 1);
		} else if (StrEqual("medic", info)) {
			clientCat[param1].meowdic = false;
			g_cookieMeowdic.SetInt(param1, 0);
		} else if (StrEqual("meowdic", info)) {
			clientCat[param1].meowdic = true;
			g_cookieMeowdic.SetInt(param1, 1);
		}
		ShowCatJournalSettingsMenu(param1);
	} else if (action == MenuAction_Cancel) {
		if (param2 == MenuCancel_ExitBack) {
			ShowCookieMenu(param1);
		}
	} else if (action == MenuAction_End) {
		delete menu;
	}
	return 0;
}

// ===== Game Events =====

public Action OnNormalSHook(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume, int &level, int &pitch, int &flags, char soundEntry[PLATFORM_MAX_PATH], int &seed) {
	if (!(1<=entity<=MaxClients) || channel != SNDCHAN_VOICE) return Plugin_Continue;
	if (!clientCat[entity].meowdic) return Plugin_Continue;
	if (StrContains(sample, "vo/") != 0) return Plugin_Continue;
	if (StrContains(sample, "Medic") < 6) return Plugin_Continue;
	if (StrContains(sample[3], "/") != -1) return Plugin_Continue;
	
	GetRandomString(g_catMeowPaths, sample, PLATFORM_MAX_PATH);
	return Plugin_Changed;
}

public void OnEntityCreated(int entity, const char[] classname) {
	if (StrEqual(classname, "player") || StrEqual(classname, "bot")) {
		SDKHook(entity, SDKHook_OnTakeDamagePost, OnTakeDamagePost);
		SDKHook(entity, SDKHook_SpawnPost, OnClientSpawnPost);
	}
}

void OnClientSpawnPost(int client) {
	clientCat[client].deathHandled=false;
	if (clientCat[client].loadState == 0) LoadCats(client);
}

void OnTakeDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype, int weapon, const float damageForce[3], const float damagePosition[3], int damagecustom) {
	if (!(1<=victim<=MaxClients)) return; //??
	if (clientCat[victim].loadState != 2) return;
	if (GetClientHealth(victim)>0) return;
	
	handleClientDeath(victim, attacker);
}

Action OnClientDeath(Event event, const char[] name, bool dontBroadcast) {
	int victim = GetClientOfUserId(event.GetInt("userid", 0));
//	int assister = GetClientOfUserId(event.GetInt("assister", 0));
	int attacker = GetClientOfUserId(event.GetInt("attacker", 0));
	handleClientDeath(victim, attacker);
	//lul we can actually set those
//	if (attacker) event.SetInt("duck_streak_total", clientCat[attacker].streak);
//	if (assister) event.SetInt("duck_streak_assist", clientCat[assister].streak);
//	if (victim) event.SetInt("duck_streak_victim", clientCat[victim].streak);
	return Plugin_Changed;
}

void handleClientDeath(int victim, int attacker) {
	if (clientCat[victim].deathHandled) return;
	clientCat[victim].deathHandled = true;
	
	if (attacker != victim && (1<=attacker<=MaxClients) &&
		GetClientTeam(victim) != GetClientTeam(attacker))
	{
		int catpower = 1;
		if (clientCat[attacker].loadState == 2) {
			catpower += clientCat[attacker].power;
			clientCat[attacker].collect(catpower, cjCreated, attacker);
			if (clientCat[attacker].addStreak(catpower)) {
				char message[128];
				FormatEx(message, sizeof(message), "%N is on a %s Streak %i", attacker, g_catThingName, clientCat[attacker].streak);
				ShowHudTextToAll(message);
			}
		}
		float pos[3];
		GetClientEyePosition(victim, pos);
		SpawnCats(victim, pos, catpower, kfNONE);
	}
	
	endCatStreak(victim, attacker);
}

void endCatStreak(int victim, int attacker) {
	//notify about victim cat-streak end
	if (clientCat[victim].streak>=10) {
		char message[128];
		if (victim == attacker || !(1<=attacker<=MaxClients))
			FormatEx(message, sizeof(message), "%N has ended their %s Streak %i", victim, g_catThingName, clientCat[victim].streak);
		else 
			FormatEx(message, sizeof(message), "%N has ended %N's %s Streak %i", attacker, victim, g_catThingName, clientCat[victim].streak);
		ShowHudTextToAll(message);
	}
	//and reset cat-streak
	clientCat[victim].streak = 0;
}

//owner: -2 for team 2 completing an objective, -3 for team 3 completing an objective
void SpawnCats(int owner, float pos[3], int cats, KibbyFlags flags) {
	float direction[3]={0.0,0.0,0.0};
//	if (1<=owner<=MaxClients && clientCat[owner].loadState==2) {
//		clientCat[owner].collect(cats, cjCreated, owner);
//	}
	int listeners[MAXPLAYERS];
	int listCount = GetClientsInMewoableRange(pos, RangeType_Audibility, listeners, MAXPLAYERS);
	char filename[PLATFORM_MAX_PATH];
	GetRandomString(g_catMeowPaths, filename, sizeof(filename));
	EmitSound(listeners, listCount, filename, SOUND_FROM_WORLD, .origin=pos);
	
	int freeEdicts = 1950-GetEntityCount();
	int headroom = 640-g_kibbyData.Length;
	if (freeEdicts < headroom) headroom = freeEdicts;
	if (headroom < cats) cats = headroom;
	if (cats <= 0) return;
	
	//leave about 100 edicts of headroom
	for (;cats-->0 && GetEntityCount()<1950;) {
		
		int cat = CreateEntityByName("prop_physics_override");
		if (cat == INVALID_ENT_REFERENCE) return;
		
		GetRandomString(g_catModelPaths, filename, sizeof(filename));
		DispatchKeyValue(cat, "model", filename);
		DispatchKeyValueFloat(cat, "modelscale", (flags & kfBonus)?0.9:0.75);
		DispatchKeyValueVector(cat, "origin", pos);
		DispatchKeyValueInt(cat, "CollisionGroup", 2); //pass-through initially
		if (!DispatchSpawn(cat)) return;
		ActivateEntity(cat);
		
		direction[0] = GetRandomFloat(-45.0,-15.0);
		direction[1] = GetRandomFloat(0.0,360.0);
		float vec[3];
		GetAngleVectors(direction, vec, NULL_VECTOR, NULL_VECTOR);
		ScaleVector(vec, GetRandomFloat(200.0, 400.0));
		TeleportEntity(cat, pos, direction, vec);
		
		float zero[3];
		if ((flags & kfBonus)==kfBonus) {
			TE_StartParticle(BONUS_GLOW, pos, zero, zero, cat, PATTACH_ROOTBONE_FOLLOW);
		} else {
			TE_StartParticle(NORMAL_GLOW, pos, zero, zero, cat, PATTACH_ROOTBONE_FOLLOW);
		}
		TE_SendToAllInRange(pos, RangeType_Visibility);
		
		KibbyData kibby;
		kibby.From(cat, owner, flags);
		g_kibbyData.PushArray(kibby);
	}
}

int ClosestPlayer(int entity, float maxDist, int touchFilter=0) {
	int clPlay;
	maxDist*=maxDist;
	float clDist=maxDist*2;
	float to[3];
	GetEntPropVector(entity, Prop_Send, "m_vecOrigin", to);
	
	for (int client=1; client<=MaxClients; client++) {
		if (!IsClientInGame(client) || GetClientTeam(client)<1 || !IsPlayerAlive(client) || client == touchFilter) continue;
		float pos[3];
		float dist;
		
		GetClientAbsOrigin(client, pos);
		if ((dist=GetVectorDistance(pos,to,true))<maxDist && dist<clDist) {
			clDist = dist; clPlay = client;
		}
		GetClientEyePosition(client, pos);
		if ((dist=GetVectorDistance(pos,to,true))<maxDist && dist<clDist) {
			clDist = dist; clPlay = client;
		}
	}
	return clPlay;
}

public Action KibbyThinkTick(Handle timer) {
	for (int i = g_kibbyData.Length-1; i>=0; i--) {
		KibbyData data;
		g_kibbyData.GetArray(i, data);
		int thinkRes = data.RemoveThink();
		if (thinkRes < 0) {
			g_kibbyData.Erase(i); continue;
		} else if (thinkRes > 0) {
			g_kibbyData.SetArray(i, data);
		}
		if ((data.flags & kfInactive)==kfInactive) {
			continue;
		}
		int catIndex = EntRefToEntIndex(data.entRef);
		//crashfix, killing a parented entity seems to cause crashes
		if (hasMoveParent(catIndex)) continue;
		
		int touchFilter = ((data.flags & kfBonus)==kfBonus && data.owner != 0) ? GetClientOfUserId(data.owner) : 0;
		int touching = ClosestPlayer(catIndex, DROP_PICKUP_RANGE, touchFilter);
		if (touching) { OnClientTouchCat(touching, data); }
	}
	return Plugin_Continue;
}

void OnClientTouchCat(int client, KibbyData data) {
	int cat = EntRefToEntIndex(data.entRef);
	if (cat == INVALID_ENT_REFERENCE) return;
	
	float pos[3];
	GetClientEyePosition(client, pos);
	int listeners[MAXPLAYERS];
	int listCount = GetClientsInMewoableRange(pos, RangeType_Audibility, listeners, MAXPLAYERS);
	char filename[PLATFORM_MAX_PATH];
	GetRandomString(g_catMeowPaths, filename, sizeof(filename));
	EmitSound(listeners, listCount, filename, SOUND_FROM_WORLD, .origin=pos);
	KillEntityAndParticleEffects(cat);
	
	if (clientCat[client].loadState != 2) return;
	
	int pickupTeam = GetClientTeam(client);
	if (data.team < 1 || (data.flags & kfBonus)==kfBonus) {
		clientCat[client].collect(1, cjBonus, client);
	} else if (data.team != pickupTeam) {
		clientCat[client].collect(1, cjCaptured, client);
	} else if ((data.flags & kfObjective)==kfObjective) {
		clientCat[client].collect(1, cjObjective, client);
	} else {
		clientCat[client].collect(1, cjRecovered, client);
		
		if (data.owner) {
			int owner = GetClientOfUserId(data.owner);
			if (1<=owner<=MaxClients && clientCat[owner].loadState == 2) {
				clientCat[owner].collect(1, cjTeamCaptured, owner);
			}
		}
	}
}

// ===== Game Objectives =====

public void OnObjectivePointCapped(Event event, const char[] name, bool dontBroadcast) {
	char cappers[MAXPLAYERS];
	event.GetString("cappers", cappers, sizeof(cappers));
	int team = event.GetInt("team");
	for (int i;cappers[i];i++) {
		if (1<=cappers[i]<=MaxClients && clientCat[cappers[i]].loadState == 2) {
			float pos[3];
			GetClientEyePosition(cappers[i], pos);
			SpawnCats(team, pos, clientCat[cappers[i]].power+1, kfObjective);
		}
	}
}

public void OnObjectiveFlagCapture(Event event, const char[] name, bool dontBroadcast) {
	int client = event.GetInt("player"); //client index?
	int eventType = event.GetInt("eventtype");
	int team = event.GetInt("team");
	if (client && clientCat[client].loadState==2 && eventType == 2) { //capture should be 2
		float pos[3];
		GetClientEyePosition(client, pos);
		SpawnCats(team, pos, clientCat[client].power+1, kfObjective);
	}
}

public void OnObjectivePasstimeScore(Event event, const char[] name, bool dontBroadcast) {
	int client = event.GetInt("scorer");
	int assister = event.GetInt("assister");
	int points = event.GetInt("points");
	int team = GetClientTeam(client);
	float pos[3];
	
	GetClientEyePosition(client, pos);
	SpawnCats(team, pos, clientCat[client].power+points, kfObjective);
	GetClientEyePosition(assister, pos);
	SpawnCats(team, pos, clientCat[assister].power+points, kfObjective);
}

// ===== Database =====

public void OnDBConnected(Database db, const char[] error, any data) {
	g_catbase = db;
	if (db == INVALID_HANDLE) {
		SetFailState("Yo, could not connect to DB: %s", error);
	}
	char tmp[12];
	db.Driver.GetIdentifier(tmp,sizeof(tmp));
	if (StrEqual("mysql", tmp)) {
		g_isMySQL = true;
	} else if (StrEqual("sqlite", tmp)) {
		g_isMySQL = false;
	} else {
		SetFailState("Unsupported Database Driver %s", tmp);
	}
	
	if (g_isMySQL) {
		db.Query(OnDBConnectedPost, "CREATE TABLE IF NOT EXISTS catjournal ("
				..."  steamid VARCHAR(32) UNIQUE,"
				..."  nickname VARCHAR(33),"
				..."  catxp INT,"
				..."  captured INT, created INT, objective INT, bonus INT, recovered INT, teamcaptured INT,"
				..."  catpower INT,"
				..."  catstreak INT"
				...") DEFAULT CHARSET=utf8mb4");
	} else {
		db.Query(OnDBConnectedPost, "CREATE TABLE IF NOT EXISTS catjournal ("
				..."  steamid VARCHAR(32) UNIQUE,"
				..."  nickname VARCHAR(33),"
				..."  catxp INT,"
				..."  captured INT, created INT, objective INT, bonus INT, recovered INT, teamcaptured INT,"
				..."  catpower INT,"
				..."  catstreak INT"
				...")");
	}
}

public void OnDBConnectedPost(Database db, DBResultSet results, const char[] error, any data) {
	for (int client=1; client<=MaxClients; client+=1) {
		if (IsClientInGame(client)) LoadCats(client);
	}
}

public void LoadCats(int client) {
	char steamid[32];
	if (IsFakeClient(client)) { clientCat[client].loadState = 2; return; }
	if (clientCat[client].loadState!=0 || g_catbase == INVALID_HANDLE) return;
	if (!IsClientAuthorized(client) || !GetClientAuthId(client, AuthId_Steam3, steamid, sizeof(steamid))) return;
	char query[256];
	g_catbase.Format(query, sizeof(query), "SELECT catxp, captured, created, objective, bonus, recovered, teamcaptured, catpower, catstreak FROM catjournal WHERE steamid = '%s'", steamid);
	g_catbase.Query(OnDBLoadClient, query, GetClientUserId(client));
	clientCat[client].loadState = 1;
}

public void OnDBLoadClient(Database db, DBResultSet results, const char[] error, any data) {
	int client = GetClientOfUserId(data);
	if (client && results.FetchRow()) {
		clientCat[client].xp = results.FetchInt(0);
		clientCat[client].journal[cjCaptured] = results.FetchInt(1);
		clientCat[client].journal[cjCreated] = results.FetchInt(2);
		clientCat[client].journal[cjObjective] = results.FetchInt(3);
		clientCat[client].journal[cjBonus] = results.FetchInt(4);
		clientCat[client].journal[cjRecovered] = results.FetchInt(5);
		clientCat[client].journal[cjTeamCaptured] = results.FetchInt(6);
		clientCat[client].power = results.FetchInt(7);
		clientCat[client].streak = results.FetchInt(8);
		if (IsClientInGame(client)) PrintJournal(client,client);
	}
	clientCat[client].loadState = 2;
}

public void SaveCats(int client) {
	if (IsFakeClient(client) || clientCat[client].loadState != 2) return; //not fully loaded, so we dont save
	char steamid[32];
	char nick[33];
	GetClientAuthId(client, AuthId_Steam3, steamid, sizeof(steamid));
	GetClientName(client, nick, sizeof(nick));
	char query[256];
	if (g_isMySQL) {
		g_catbase.Format(query, sizeof(query), "REPLACE INTO catjournal (steamid, nickname, catxp, captured, created, objective, bonus, recovered, teamcaptured, catpower, catstreak) VALUES ('%s', '%s', %i, %i, %i, %i, %i, %i, %i, %i, %i)", 
			steamid, nick, clientCat[client].xp, clientCat[client].journal[cjCaptured], clientCat[client].journal[cjCreated],
			clientCat[client].journal[cjObjective], clientCat[client].journal[cjBonus], clientCat[client].journal[cjRecovered],
			clientCat[client].journal[cjTeamCaptured], clientCat[client].power, clientCat[client].streak);
	} else {
		g_catbase.Format(query, sizeof(query), "INSERT OR REPLACE INTO catjournal (steamid, nickname, catxp, captured, created, objective, bonus, recovered, teamcaptured, catpower, catstreak) VALUES ('%s', '%s', %i, %i, %i, %i, %i, %i, %i, %i, %i)", 
			steamid, nick, clientCat[client].xp, clientCat[client].journal[cjCaptured], clientCat[client].journal[cjCreated],
			clientCat[client].journal[cjObjective], clientCat[client].journal[cjBonus], clientCat[client].journal[cjRecovered],
			clientCat[client].journal[cjTeamCaptured], clientCat[client].power, clientCat[client].streak);
	}
	g_catbase.Query(OnDBSaveClient, query, GetClientUserId(client));
}

public void OnDBSaveClient(Database db, DBResultSet results, const char[] error, any data) {}

// ===== Stuff =====

void ShowHudTextToAll(const char[] message, int r=255, int g=175, int b=0) {
	SetHudTextParams(-1.0, 0.2, 5.0, r,g,b, 255, 0, 1.0);
	for (int client=1;client<=MaxClients;client+=1) {
		if (IsClientInGame(client) && GetClientTeam(client)!=0) {
			ShowHudText(client, -1, "%s", message);
		}
	}
}

bool hasMoveParent(int ent) {
	return GetEntPropEnt(ent, Prop_Send, "moveparent") != INVALID_ENT_REFERENCE;
}

int GetClientsInMewoableRange(const float origin[3], ClientRangeType rangeType, int[] clients, int size) {
	int all[MAXPLAYERS];
	int amount = GetClientsInRange(origin, rangeType, all, sizeof(all));
	int result;
	for (int i; i<amount && i<size; i++) {
		int client = all[i];
		if (clientCat[client].loadState == 2 && !clientCat[client].muted) {
			clients[result] = client;
			result += 1;
		}
	}
	return result;
}

/** This makes sure to tell clients to end the particle effects before removing
 * the entity, by DispatchEffect ParticleEffectStop, and actual deletion of the 
 * entity being delayed by 1 tick. This wont work OnPluginEnd or on map change.
 */
void KillEntityAndParticleEffects(int entity) {
	SetVariantString("ParticleEffectStop");
	AcceptEntityInput(entity, "DispatchEffect");
	RequestFrame(_KillEntityAndParticleEffects_DelayedKill, EntIndexToEntRef(entity));
}
/// Internal callback for KillEntityAndParticleEffects
static void _KillEntityAndParticleEffects_DelayedKill(int entref) {
	int entity = EntRefToEntIndex(entref);
	if (entity) AcceptEntityInput(entity, "Kill");
}

static void GetRandomString(ArrayList list, char[] buffer, int size) {
	list.GetString(GetURandomInt() % list.Length, buffer, size);
}
