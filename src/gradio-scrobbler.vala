/* Original Authors: The GNOME Music Developers
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or(at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public
 * License along with this library; if not, write to the
 * Free Software Foundation, Inc., 59 Temple Place - Suite 330,
 * Boston, MA 02111-1307, USA.
 */

public class Gradio.Scrobbler: GLib.Object {
	private GoaLastFM goa_lastfm = null;
	private Soup.Session soup_session = null;
	private Track? current_track = null;

	public Scrobbler() {
		goa_lastfm = new GoaLastFM();

		soup_session = new Soup.Session();
		soup_session.user_agent = "gradio/" + Config.VERSION;

		App.player.notify["current-title-tag"].connect(song_changed);
	}

	private void song_changed() {
		if(App.player.station != null && App.player.current_title_tag != null) {
			string new_artist = App.player.station.title;
			string new_title = App.player.current_title_tag;

			if (new_artist != current_track.artist || new_title != current_track.title) {
				// TODO: track duration, we should not scrobble tracks shorter than 30 seconds, and only when the user heard most of the song
				// TODO: we should also filter out ads and other non-songs
				scrobble(current_track, GLib.TimeVal());

				current_track = Track() {
					artist = new_artist,
					title = new_title,
					// TODO: implement albums
					album = null
				};

				now_playing(current_track);
			}
		}
	}

	/**
	 * Submit a request to AudioScrobbler
	 *
	 * @see https://www.last.fm/api/scrobbling
	 */
	private void lastfm_api_call(Track media, TimeVal? time_stamp, ScrobblerAction request_type) {
		string api_key = goa_lastfm.client_id;
		string sk = goa_lastfm.session_key;
		string secret = goa_lastfm.secret;

		HashTable<string, string> request_dict = new HashTable<string, string>(str_hash, str_equal);

		// The album is optional. So only provide it when it is available.
		if(media.album != null) {
			request_dict.insert("album", media.album);
		}

		if(time_stamp != null) {
			request_dict.insert("timestamp", "%ld".printf(time_stamp.tv_sec));
		}

		request_dict.insert("api_key", api_key);

		switch(request_type) {
			case ScrobblerAction.UPDATE_NOW_PLAYING:
				request_dict.insert("method", "track.updateNowPlaying");
				break;
			case ScrobblerAction.SCROBBLE:
				request_dict.insert("method", "track.scrobble");
				break;
		}

		request_dict.insert("artist", media.artist);
		request_dict.insert("track", media.title);
		request_dict.insert("sk", sk);

		// The request needs to be authenticated
		// https://www.last.fm/api/authspec#8
		string sig = "";
		request_dict.for_each((key, val) => {
			sig += key + val;
		});
		sig += secret;

		// TODO: api_sig should be md5(sig)
		string api_sig = sig;
		request_dict.insert("api_sig", api_sig);

		try {
			Soup.Message msg = Soup.Form.request_new_from_hash("POST", "https://ws.audioscrobbler.com/2.0/", request_dict);
			soup_session.send_async(msg);
			// TODO: Error handling
			// if(mess.status_code != Soup.Status.OK) {
			// 	switch (request_type) {
			// 		case UPDATE_NOW_PLAYING:
			// 			warning("Failed to update now playing track: %s", Soup.Status.get_phrase(mess.status_code));
			// 			break;
			// 		case SCROBBLE:
			// 			warning("Failed to scrobble track: %s", Soup.Status.get_phrase(mess.status_code));
			// 			break;
			// 	}
			// 	warning(r.response_body.data);
			// }
		} catch(GLib.Error e) {
			warning("Failed to contact AudioScrobbler: %s", e.message);
		}
	}

	public void scrobble(Track media, TimeVal? time_stamp) {
		if(goa_lastfm.disabled) {
			return;
		}

		// TODO: run this in a thread
		lastfm_api_call(media, time_stamp, ScrobblerAction.SCROBBLE);
	}

	public void now_playing(Track media) {
		if(goa_lastfm.disabled) {
			return;
		}

		// TODO: run this in a thread
		lastfm_api_call(media, null, ScrobblerAction.UPDATE_NOW_PLAYING);
	}
}

public struct Track {
	public string title;
	public string artist;
	public string? album;
}

private enum ScrobblerAction {
	UPDATE_NOW_PLAYING, SCROBBLE;
}


public class GoaLastFM : GLib.Object {
	private Goa.Client client = null;
	private Goa.Account account = null;
	private Goa.OAuth2Based authentication = null;
	public bool disabled = true;

	public GoaLastFM() {
		// TODO: use async constructor
		try {
			client = new Goa.Client.sync(null);
			client.account_added.connect(goa_account_mutation);
			client.account_removed.connect(goa_account_mutation);
			find_lastfm_account();
		} catch(GLib.Error error) {
			warning("Error: %d, %s", error.code, error.message);
			return;
		}
	}

	private void goa_account_mutation(Goa.Object obj) {
		find_lastfm_account();
	}

	private void find_lastfm_account() {
		List<Goa.Object> accounts = client.get_accounts();

		foreach(Goa.Object obj in accounts) {
			Goa.Account goa_account = obj.get_account();
			if(goa_account.provider_type == "lastfm") {
				authentication = obj.get_oauth2_based();
				account = goa_account;
				disabled = goa_account.music_disabled;
				goa_account.notify["music-disabled"].connect(on_goa_music_disabled);
				break;
			}
		}
	}

	private void on_goa_music_disabled(GLib.Object s, GLib.ParamSpec p) {
		Goa.Account account = (Goa.Account) s;
		disabled = account.music_disabled;
	}

	public string secret {
		owned get {
			return authentication.client_secret;
		}
	}

	public string client_id {
		owned get {
			return authentication.client_id;
		}
	}

	public string session_key {
		owned get {
			// TODO: handle error
			string out_access_token;
			int out_expires_in;
			authentication.call_get_access_token_sync(out out_access_token, out out_expires_in);
			return out_access_token;
		}
	}
}
