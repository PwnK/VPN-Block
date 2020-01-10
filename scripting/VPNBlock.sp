#include <sourcemod>
#include <SteamWorks>

#pragma semicolon 1
#pragma newdecls required

#define PDAYS 30

public Plugin myinfo =  {
	name = "VPN Block",
	author = "PwnK, updated by JoinedSenses",
	description = "Blocks VPNs",
	version = "2.0.0",
	url = "https://pelikriisi.fi/"
};

Database g_db;

ConVar gcv_KickClients;
ConVar gcv_url;
ConVar gcv_response;

public void OnPluginStart() {
	LoadTranslations ("vpnblock.phrases");

	Database.Connect(SQLHandler_Connect, SQL_CheckConfig("VPNBlock") ? "VPNBlock" : "default");

	RegAdminCmd("sm_vbwhitelist", CommandWhiteList, ADMFLAG_ROOT, "sm_vbwhitelist \"<SteamID>\"");
	RegAdminCmd("sm_vbunwhitelist", CommandUnWhiteList, ADMFLAG_ROOT, "sm_vbunwhitelist \"<SteamID>\"");
	
	gcv_KickClients = CreateConVar("vpnblock_kickclients", "1", "1 = Kick and log client when he tries to join with a VPN 0 = only log", _, true, 0.0, true, 1.0);
	gcv_url = CreateConVar("vpnblock_url", "http://proxy.mind-media.com/block/proxycheck.php?ip={IP}", "The url used to check proxies.");
	gcv_response = CreateConVar("vpnblock_response", "Y", "If the response contains this it means the player is using a VPN.");

	AutoExecConfig(true, "VPNBlock");
}

public void SQLHandler_Connect(Database db, const char[] error, any data) {
	if (db == null || error[0] != '\0') {
		SetFailState("Unable to connect to database (%s)", error);
	}

	g_db = db;
	g_db.Query(SQLHandler_CreateVPNTable, "CREATE TABLE IF NOT EXISTS `VPNBlock` (`playername` char(128) NOT NULL, `steamid` char(32) NOT NULL, `lastupdated` int(64) NOT NULL, `ip` char(32) NOT NULL, `proxy` boolean NOT NULL, PRIMARY KEY (`ip`))");
	g_db.Query(SQLHandler_InsertPlayerData, "CREATE TABLE IF NOT EXISTS `VPNBlock_wl` (`steamid` char(32) NOT NULL, PRIMARY KEY (`steamid`))");
}

public void SQLHandler_CreateVPNTable(Database db, DBResultSet results, const char[] error, any data) {
	if (db == null || results == null || error[0] != '\0') {
		VPNBlock_Log(2, _, _, error);
		return;
	}

	PruneDatabase();
}

public void OnClientAuthorized(int client, const char[] auth) {
	if (IsFakeClient(client)) {
		return;
	}

	char buffer[256];
	Format(buffer, sizeof(buffer), "SELECT * FROM `VPNBlock_wl` WHERE `steamid` = '%s'", auth[8]);

	g_db.Query(SQLHandler_CheckWhitelist, buffer, GetClientUserId(client));
}

public void SQLHandler_CheckWhitelist(Database db, DBResultSet results, const char[] error, int userid) {
	if (db == null || results == null || error[0] != '\0') {
		VPNBlock_Log(2, _, _, error);
		return;
	}
	
	if (results.RowCount) {
		return;
	}

	int client = GetClientOfUserId(userid);
	if (!client) {
		return;
	}

	char ip[30];
	GetClientIP(client, ip, sizeof(ip));

	char buffer[256];
	Format(buffer, sizeof(buffer), "SELECT `proxy` FROM `VPNBlock` WHERE `ip` = '%s'", ip);

	g_db.Query(SQLHandler_CheckVPN, buffer, userid);
}

public void SQLHandler_CheckVPN(Database db, DBResultSet results, const char[] error, int userid) {
	if (db == null || results == null || error[0] != '\0') {
		VPNBlock_Log(2, _, _, error);
		return;
	}

	int client = GetClientOfUserId(userid);
	if (!client) {
		return;
	}

	char ip[30];
	GetClientIP(client, ip, sizeof(ip));

	if (results.RowCount == 0 || !results.FetchRow()) {
		Http_CheckIp(ip, client);
	}
	else if (results.FetchInt(0) == 1) {
		VPNBlock_Log(0, client, ip);
		
		if (gcv_KickClients.BoolValue) {
			KickClient(client, "%t", "VPN Kick");
		}
	}
}

void Http_CheckIp(char[] ip, int client) {
	DataPack pack = new DataPack();
	pack.WriteString(ip);
	pack.WriteCell(GetClientUserId(client));

	char url[85];
	gcv_url.GetString(url, sizeof(url));
	ReplaceString(url, sizeof(url), "{IP}", ip, true);

	Handle CheckIp = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
	SteamWorks_SetHTTPCallbacks(CheckIp, HttpResponseCompleted, _, HttpResponseDataReceived);
	SteamWorks_SetHTTPRequestContextValue(CheckIp, pack);
	SteamWorks_SetHTTPRequestNetworkActivityTimeout(CheckIp, 5);
	SteamWorks_SendHTTPRequest(CheckIp);
}

public int Http_RequestData(const char[] content, DataPack pack) {
	char steamid[28], name[100], ip[30];
	pack.Reset();
	pack.ReadString(ip, sizeof(ip));
	int client = GetClientOfUserId(pack.ReadCell());
	delete pack;

	if (!client || !IsClientConnected(client)) {
		return;
	}

	GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));
	GetClientName(client, name, sizeof(name));

	int buffer_len = strlen(name) * 2 + 1;
	char[] newname = new char[buffer_len];
	g_db.Escape(name, newname, buffer_len);

	int proxy;
	char responsevpn[30];
	gcv_response.GetString(responsevpn, sizeof(responsevpn));
	
	if (StrContains(content, responsevpn) != -1) {
		VPNBlock_Log(0, client, ip);
		if (gcv_KickClients.BoolValue) {
			KickClient(client, "%t", "VPN Kick");
		}
		proxy = 1;
	}
	else {
		proxy = 0;
	}

	char query[300];
	Format(query, sizeof(query), "INSERT INTO `VPNBlock`(`playername`, `steamid`, `lastupdated`, `ip`, `proxy`) VALUES('%s', '%s', '%d', '%s', '%d');", newname, steamid, GetTime(), ip, proxy);

	g_db.Query(SQLHandler_InsertPlayerData, query);
}

public void SQLHandler_InsertPlayerData(Database db, DBResultSet results, const char[] error, any data) {
	if (db == null || results == null || error[0] != '\0') {
		VPNBlock_Log(2, _, _, error);
	}
}

public int HttpResponseDataReceived(Handle request, bool failure, int offset, int bytesReceived, DataPack pack) {
	SteamWorks_GetHTTPResponseBodyCallback(request, Http_RequestData, pack);
	delete request;
}

public int HttpResponseCompleted(Handle request, bool failure, bool requestSuccessful, EHTTPStatusCode statusCode, DataPack pack) {
	if(failure || !requestSuccessful) {
		VPNBlock_Log(1);
		delete pack;
		delete request;
	}
}

void PruneDatabase() {
	int maxlastupdated = GetTime() - (PDAYS * 86400);

	char buffer[256];
	Format(buffer, sizeof(buffer), "DELETE FROM `VPNBlock` WHERE `lastupdated`<'%d';", maxlastupdated);

	g_db.Query(SQLHandler_Prune, buffer);
}

public void SQLHandler_Prune(Database db, DBResultSet results, const char[] error, any data) {
	if (db == null || results == null || error[0] != '\0') {
		VPNBlock_Log(2, _, _, error);
	}
}

public Action CommandWhiteList(int client, int args) {
	if (args != 1) {
		ReplyToCommand(client, "[SM] Usage: sm_vbwhitelist \"<SteamID>\"");
		return Plugin_Handled;
	}
	
	WhiteList(true);
	return Plugin_Handled;
}

public Action CommandUnWhiteList(int client, int args) {
	if (args != 1) {
		ReplyToCommand(client, "[SM] Usage: sm_vbunwhitelist \"<SteamID>\"");
		return Plugin_Handled;
	}
	
	WhiteList(false);
	return Plugin_Handled;
}

void WhiteList(bool whitelist) {
	char steamid[28];
	GetCmdArgString(steamid, sizeof(steamid));
	StripQuotes(steamid);

	if (StrContains(steamid, "STEAM_") == 0) {
		strcopy(steamid, sizeof(steamid), steamid[8]);
	}
	
	int buffer_len = strlen(steamid) * 2 + 1;
	char[] escsteamid = new char[buffer_len];
	g_db.Escape(steamid, escsteamid, buffer_len);
	
	char query[100];
	if (whitelist) {
		Format(query, sizeof(query), "INSERT INTO `VPNBlock_wl`(`steamid`) VALUES('%s');", escsteamid);
	}
	else {
		Format(query, sizeof(query), "DELETE FROM `VPNBlock_wl` WHERE `steamid`='%s';", escsteamid);
	}

	g_db.Query(SQLHandler_InsertPlayerData, query);
}

void VPNBlock_Log(int logtype, int client = 0, char[] ip = "", const char[] error = "") {
	char date[32];
	FormatTime(date, sizeof(date), "%d/%m/%Y %H:%M:%S", GetTime());

	static char LogPath[PLATFORM_MAX_PATH];
	if (LogPath[0] == '\0') {
		BuildPath(Path_SM, LogPath, sizeof(LogPath), "logs/VPNBlock_Log.txt");
	}

	File logFile = OpenFile(LogPath, "a");

	if (logtype == 0) {
		char steamid[28];
		GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));

		char name[100];
		GetClientName(client, name, sizeof(name));

		logFile.WriteLine("[VPNBlock] %T", "Log VPN Kick", LANG_SERVER, date, name, steamid, ip);
	}
	else if (logtype == 1) {
		logFile.WriteLine("[VPNBlock] %T", "Http Error", LANG_SERVER, date);
	}
	else {
		logFile.WriteLine("[VPNBlock] %T", "Query Failure", LANG_SERVER, date, error);
	}

	delete logFile;
}