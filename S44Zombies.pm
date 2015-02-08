package S44Zombies;
use strict;
use warnings;
use SpadsPluginApi;
use Data::Dumper qw(Dumper);
use Mojo::IOLoop;
use Mojo::UserAgent;
use 5.20.1;

use experimental qw(signatures postderef);
use JSON::MaybeXS;
use Digest::xxHash qw(xxhash_hex);

#see https://github.com/spring/spring/blob/HEAD/rts/Lua/LuaHandle.h#L22
#these define "script_type" in the SpringAutohostInterface GAME_LUAMSG interface
use constant LUARULES_MSG => 100;

no warnings 'redefine';

# TODO: queue API calls and only remove them from queue on confirm by
# server that they were accepted

sub getVersion { '0.1' }
sub getRequiredSpadsVersion { '0.11' }

my %globalPluginParams = ( commandsFile => ['notNull'],
                           helpFile => ['notNull'] );
sub getParams { return [\%globalPluginParams,{}]; }

my $host = "localhost:3000";

sub eventLoop {
    my $id = Mojo::IOLoop->timer(0.05 => sub {});
    Mojo::IOLoop->one_tick;
    Mojo::IOLoop->remove($id);
};

my $ua = Mojo::UserAgent->new;

my %zombies_command_handlers = (
    'team-ready' => sub($game_id, $autohost, $data) {
        say "got a team ready message: " . Dumper($data);
        my ($player_name, $team_id) = $data->@{qw(name teamID)};
        $ua->get("$host/$player_name" => sub ($self, $tx) {
            my $json = $tx->res->json;
            say "got a team-ready response for $player_name";
            $json->{teamID} = $team_id;
            say "spawning a team!", Dumper($json);
            $autohost->sendChatMessage("/luarules spawn-team  " . encode_json($json));
        });
    },

    'save-unit' => sub ($game_id, $autohost, $data) {
        say "got a save-data message: " . Dumper($data);
        my $saved = 0;
        my $player_name = $data->{name};
        $ua->post("$host/$player_name/surviving_unit" => json => $data->{unit} => sub ($self, $tx) {
            $saved = 1;
        });
    },
    reward => sub ($game_id, $autohost, $data) {
        say "got a reward: " . Dumper($data);
        my $success = 0;
        my $player_name = $data->{name};
        $ua->post("$host/$player_name/bank" => json => $data => sub ($self, $tx) {
            $success = 1;
        });
    }
);

sub dispatch_message ($game_id, $autohost, $raw_message) {
    my $message;
    # Try::Tiny would be nicer looking, but it uses subs, so  you can't return out of the
    # catch block.
    eval {
        $message = decode_json($raw_message);
        1;
    } or do {
        my $err = $@ || "blorg false-y error";
        say "this message doesn't taste like JSON, or something: $err and $raw_message";
        return;
    };
    my ($command, $data) = $message->@{qw(command data)};

    if ($zombies_command_handlers{$command}) {
        $zombies_command_handlers{$command}->($game_id, $autohost, $data);
    } else {
        say "no such command: $command~!";
    }
}

sub game_end ($game_id) {
    $ua->post("$host/games/$game_id/end" => sub ($self, $tx) { });
}

sub new ($class) {
    my $self = {};
    bless($self, $class);
    my $autohost = getSpringInterface();
    my $db;
    my $game_id;
    my %message_hash;
    my $num_players_running_sim;
    my $seed;

    addSpringCommandHandler({SERVER_STARTPLAYING => sub {
        $game_id = $autohost->{gameId};
        $seed = rand;
        %message_hash = ();

        # get them by IP address and count?
        # we're mostly interested in the number of spring sims running, which
        # relates to how many copies of a particular message we will get.
        # note: this ignores bots, which is a pain. they're not in the players
        # hash at all.
        my @players = keys $autohost->{players}->%*;
        $num_players_running_sim = scalar @players;
        $ua->post("$host/games/$game_id/start" => json => [@players] => sub ($self, $tx) { });
    }});

    addSpringCommandHandler({PLAYER_JOINED => sub { $num_players_running_sim++ }});
    addSpringCommandHandler({PLAYER_LEFT => sub { $num_players_running_sim-- }});

    # TODO: assign some unique prefix or something to zombies messages. right
    # now it relies on the fact that only messages sent by a majority of
    # players are dispatched and decoded. script type being luarules msg does
    # limit the confusion though
    addSpringCommandHandler({GAME_LUAMSG => sub ($message_type, $source_player, $script_type, $mode, $data) {
        if ($script_type eq LUARULES_MSG) {
            say "player $source_player sent '$data' via script type $script_type using mode $mode";
            my $fingerprint = xxhash_hex($data, $seed);
            $message_hash{$fingerprint} //= { seen => 0, sent => 0};
            my $message = $message_hash{$fingerprint};
            my $seen = ++$message->{seen};
            my $sent = $message->{sent};
            # this could probably also use a minimum of 2, but that would make my
            # testing life difficult, and zombies isn't a 1v1 game.
            say "message has fingerprint $fingerprint has been seen " . $seen . " times";
            if ($seen >= $num_players_running_sim / 2 and not $sent) {
                $message->{sent} = time;
                dispatch_message($game_id, $autohost, $data);
            }
        }
    }});

    addSpringCommandHandler({SERVER_GAMEOVER => sub { say "sending game end: $game_id"; game_end($game_id) }});
    # in case it fails for some reason
    addSpringCommandHandler({SERVER_QUIT => sub { say "sending game end: $game_id"; game_end($game_id) }});

    my $builtin_start = $::spadsHandlers{start};

    addSpadsCommandHandler({start => sub ($source, $username, $params, $checkOnly) {
        my $battle = getLobbyInterface()->getBattle();
        my $users = $battle->{users};
        my $bots = $battle->{bots};
        my $merged = { $bots->%*, $users->%* };
        my %players;
        for my $name (keys $merged->%*) {
            my $participant = $merged->{$name};
            if ($participant->{battleStatus}->{mode} eq '1') {
                $players{$name} = $participant;
            }
        }

        $ua->post("$host/valid_teams" => json => \%players => sub ($ua, $tx) {
            my $res = $tx->res->json;
            if ($res->{ok}) {
                $builtin_start->(@_);
            } else {
                sayBattle("NOT OK");
            }
        });
    }}, 1);

    addSpadsCommandHandler({hq => sub ($source, $user, $params, $checkOnly) {
        $ua->get("$host/hq/$user" => sub ($ua, $tx) {
            sayPrivate($user, "server says: " . $tx->res->text);
        });
    }});

    return $self;
}

1;
