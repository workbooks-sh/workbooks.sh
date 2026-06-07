import init, { random_brand, roll_name, colors_json, glyphs_for } from '../pkg/adbuy_sim.js'
import { writeSave, readSave } from '../save.js'
/* ===== static presentation atoms (CSS + icon-name mapping only; recipe/colors/names come from WASM) ===== */
const CONTAINERS = ["shield","circle","lozenge","crest","banner","hex","rounded_sq","diamond","oval","badge","ribbon","seal"];
const FONTS = [{id:"fraunces",label:"Fraunces",cls:"f-fraunces"},{id:"archivo",label:"Archivo",cls:"f-archivo"},{id:"baloo",label:"Baloo",cls:"f-baloo"}];
const LAYOUTS = ["stacked","horizontal","emblem"];
const ICONS = ["acorn","activity","address-book","address-book-tabs","air-traffic-control","airplane","airplane-in-flight","airplane-landing","airplane-takeoff","airplane-taxiing","airplane-tilt","airplay","alarm","alien","align-bottom","align-bottom-simple","align-center-horizontal","align-center-horizontal-simple","align-center-vertical","align-center-vertical-simple","align-left","align-left-simple","align-right","align-right-simple","align-top","align-top-simple","amazon-logo","ambulance","anchor","anchor-simple","android-logo","angle","angular-logo","aperture","app-store-logo","app-window","apple-logo","apple-podcasts-logo","approximate-equals","archive","archive-box","archive-tray","armchair","arrow-arc-left","arrow-arc-right","arrow-bend-double-up-left","arrow-bend-double-up-right","arrow-bend-down-left","arrow-bend-down-right","arrow-bend-left-down","arrow-bend-left-up","arrow-bend-right-down","arrow-bend-right-up","arrow-bend-up-left","arrow-bend-up-right","arrow-circle-down","arrow-circle-down-left","arrow-circle-down-right","arrow-circle-left","arrow-circle-right","arrow-circle-up","arrow-circle-up-left","arrow-circle-up-right","arrow-clockwise","arrow-counter-clockwise","arrow-down","arrow-down-left","arrow-down-right","arrow-elbow-down-left","arrow-elbow-down-right","arrow-elbow-left","arrow-elbow-left-down","arrow-elbow-left-up","arrow-elbow-right","arrow-elbow-right-down","arrow-elbow-right-up","arrow-elbow-up-left","arrow-elbow-up-right","arrow-fat-down","arrow-fat-left","arrow-fat-line-down","arrow-fat-line-left","arrow-fat-line-right","arrow-fat-line-up","arrow-fat-lines-down","arrow-fat-lines-left","arrow-fat-lines-right","arrow-fat-lines-up","arrow-fat-right","arrow-fat-up","arrow-left","arrow-line-down","arrow-line-down-left","arrow-line-down-right","arrow-line-left","arrow-line-right","arrow-line-up","arrow-line-up-left","arrow-line-up-right","arrow-right","arrow-square-down","arrow-square-down-left","arrow-square-down-right","arrow-square-in","arrow-square-left","arrow-square-out","arrow-square-right","arrow-square-up","arrow-square-up-left","arrow-square-up-right","arrow-u-down-left","arrow-u-down-right","arrow-u-left-down","arrow-u-left-up","arrow-u-right-down","arrow-u-right-up","arrow-u-up-left","arrow-u-up-right","arrow-up","arrow-up-left","arrow-up-right","arrows-clockwise","arrows-counter-clockwise","arrows-down-up","arrows-horizontal","arrows-in","arrows-in-cardinal","arrows-in-line-horizontal","arrows-in-line-vertical","arrows-in-simple","arrows-left-right","arrows-merge","arrows-out","arrows-out-cardinal","arrows-out-line-horizontal","arrows-out-line-vertical","arrows-out-simple","arrows-split","arrows-vertical","article","article-medium","article-ny-times","asclepius","asterisk","asterisk-simple","at","atom","avocado","axe","baby","baby-carriage","backpack","backspace","bag","bag-simple","balloon","bandaids","bank","barbell","barcode","barn","barricade","baseball","baseball-cap","baseball-helmet","basket","basketball","bathtub","battery-charging","battery-charging-vertical","battery-empty","battery-full","battery-high","battery-low","battery-medium","battery-plus","battery-plus-vertical","battery-vertical-empty","battery-vertical-full","battery-vertical-high","battery-vertical-low","battery-vertical-medium","battery-warning","battery-warning-vertical","beach-ball","beanie","bed","beer-bottle","beer-stein","behance-logo","bell","bell-ringing","bell-simple","bell-simple-ringing","bell-simple-slash","bell-simple-z","bell-slash","bell-z","belt","bezier-curve","bicycle","binary","binoculars","biohazard","bird","blueprint","bluetooth","bluetooth-connected","bluetooth-slash","bluetooth-x","boat","bomb","bone","book","book-bookmark","book-open","book-open-text","book-open-user","bookmark","bookmark-simple","bookmarks","bookmarks-simple","books","boot","boules","bounding-box","bowl-food","bowl-steam","bowling-ball","box-arrow-down","box-arrow-up","boxing-glove","brackets-angle","brackets-curly","brackets-round","brackets-square","brain","brandy","bread","bridge","briefcase","briefcase-metal","broadcast","broom","browser","browsers","bug","bug-beetle","bug-droid","building","building-apartment","building-office","buildings","bulldozer","bus","butterfly","cable-car","cactus","caduceus","cake","calculator","calendar","calendar-blank","calendar-check","calendar-dot","calendar-dots","calendar-heart","calendar-minus","calendar-plus","calendar-slash","calendar-star","calendar-x","call-bell","camera","camera-plus","camera-rotate","camera-slash","campfire","car","car-battery","car-profile","car-simple","cardholder","cards","cards-three","caret-circle-double-down","caret-circle-double-left","caret-circle-double-right","caret-circle-double-up","caret-circle-down","caret-circle-left","caret-circle-right","caret-circle-up","caret-circle-up-down","caret-double-down","caret-double-left","caret-double-right","caret-double-up","caret-down","caret-left","caret-line-down","caret-line-left","caret-line-right","caret-line-up","caret-right","caret-up","caret-up-down","carrot","cash-register","cassette-tape","castle-turret","cat","cell-signal-full","cell-signal-high","cell-signal-low","cell-signal-medium","cell-signal-none","cell-signal-slash","cell-signal-x","cell-tower","certificate","chair","chalkboard","chalkboard-simple","chalkboard-teacher","champagne","charging-station","chart-bar","chart-bar-horizontal","chart-donut","chart-line","chart-line-down","chart-line-up","chart-pie","chart-pie-slice","chart-polar","chart-scatter","chat","chat-centered","chat-centered-dots","chat-centered-slash","chat-centered-text","chat-circle","chat-circle-dots","chat-circle-slash","chat-circle-text","chat-dots","chat-slash","chat-teardrop","chat-teardrop-dots","chat-teardrop-slash","chat-teardrop-text","chat-text","chats","chats-circle","chats-teardrop","check","check-circle","check-fat","check-square","check-square-offset","checkerboard","checks","cheers","cheese","chef-hat","cherries","church","cigarette","cigarette-slash","circle","circle-dashed","circle-half","circle-half-tilt","circle-notch","circle-wavy","circle-wavy-check","circle-wavy-question","circle-wavy-warning","circles-four","circles-three","circles-three-plus","circuitry","city","clipboard","clipboard-text","clock","clock-afternoon","clock-clockwise","clock-countdown","clock-counter-clockwise","clock-user","closed-captioning","cloud","cloud-arrow-down","cloud-arrow-up","cloud-check","cloud-fog","cloud-lightning","cloud-moon","cloud-rain","cloud-slash","cloud-snow","cloud-sun","cloud-warning","cloud-x","clover","club","coat-hanger","coda-logo","code","code-block","code-simple","codepen-logo","codesandbox-logo","coffee","coffee-bean","coin","coin-vertical","coins","columns","columns-plus-left","columns-plus-right","command","compass","compass-rose","compass-tool","computer-tower","confetti","contactless-payment","control","cookie","cooking-pot","copy","copy-simple","copyleft","copyright","corners-in","corners-out","couch","court-basketball","cow","cowboy-hat","cpu","crane","crane-tower","credit-card","cricket","crop","cross","crosshair","crosshair-simple","crown","crown-cross","crown-simple","cube","cube-focus","cube-transparent","currency-btc","currency-circle-dollar","currency-cny","currency-dollar","currency-dollar-simple","currency-eth","currency-eur","currency-gbp","currency-inr","currency-jpy","currency-krw","currency-kzt","currency-ngn","currency-rub","cursor","cursor-click","cursor-text","cylinder","database","desk","desktop","desktop-tower","detective","dev-to-logo","device-mobile","device-mobile-camera","device-mobile-slash","device-mobile-speaker","device-rotate","device-tablet","device-tablet-camera","device-tablet-speaker","devices","diamond","diamonds-four","dice-five","dice-four","dice-one","dice-six","dice-three","dice-two","disc","disco-ball","discord-logo","divide","dna","dog","door","door-open","dot","dot-outline","dots-nine","dots-six","dots-six-vertical","dots-three","dots-three-circle","dots-three-circle-vertical","dots-three-outline","dots-three-outline-vertical","dots-three-vertical","download","download-simple","dress","dresser","dribbble-logo","drone","drop","drop-half","drop-half-bottom","drop-simple","drop-slash","dropbox-logo","ear","ear-slash","egg","egg-crack","eject","eject-simple","elevator","empty","engine","envelope","envelope-open","envelope-simple","envelope-simple-open","equalizer","equals","eraser","escalator-down","escalator-up","exam","exclamation-mark","exclude","exclude-square","export","eye","eye-closed","eye-slash","eyedropper","eyedropper-sample","eyeglasses","eyes","face-mask","facebook-logo","factory","faders","faders-horizontal","fallout-shelter","fan","farm","fast-forward","fast-forward-circle","feather","fediverse-logo","figma-logo","file","file-archive","file-arrow-down","file-arrow-up","file-audio","file-c","file-c-sharp","file-cloud","file-code","file-cpp","file-css","file-csv","file-dashed","file-doc","file-dotted","file-html","file-image","file-ini","file-jpg","file-js","file-jsx","file-lock","file-magnifying-glass","file-md","file-minus","file-pdf","file-plus","file-png","file-ppt","file-py","file-rs","file-search","file-sql","file-svg","file-text","file-ts","file-tsx","file-txt","file-video","file-vue","file-x","file-xls","file-zip","files","film-reel","film-script","film-slate","film-strip","fingerprint","fingerprint-simple","finn-the-human","fire","fire-extinguisher","fire-simple","fire-truck","first-aid","first-aid-kit","fish","fish-simple","flag","flag-banner","flag-banner-fold","flag-checkered","flag-pennant","flame","flashlight","flask","flip-horizontal","flip-vertical","floppy-disk","floppy-disk-back","flow-arrow","flower","flower-lotus","flower-tulip","flying-saucer","folder","folder-dashed","folder-dotted","folder-lock","folder-minus","folder-notch","folder-notch-minus","folder-notch-open","folder-notch-plus","folder-open","folder-plus","folder-simple","folder-simple-dashed","folder-simple-dotted","folder-simple-lock","folder-simple-minus","folder-simple-plus","folder-simple-star","folder-simple-user","folder-star","folder-user","folders","football","football-helmet","footprints","fork-knife","four-k","frame-corners","framer-logo","function","funnel","funnel-simple","funnel-simple-x","funnel-x","game-controller","garage","gas-can","gas-pump","gauge","gavel","gear","gear-fine","gear-six","gender-female","gender-intersex","gender-male","gender-neuter","gender-nonbinary","gender-transgender","ghost","gif","gift","git-branch","git-commit","git-diff","git-fork","git-merge","git-pull-request","github-logo","gitlab-logo","gitlab-logo-simple","globe","globe-hemisphere-east","globe-hemisphere-west","globe-simple","globe-simple-x","globe-stand","globe-x","goggles","golf","goodreads-logo","google-cardboard-logo","google-chrome-logo","google-drive-logo","google-logo","google-photos-logo","google-play-logo","google-podcasts-logo","gps","gps-fix","gps-slash","gradient","graduation-cap","grains","grains-slash","graph","graphics-card","greater-than","greater-than-or-equal","grid-four","grid-nine","guitar","hair-dryer","hamburger","hammer","hand","hand-arrow-down","hand-arrow-up","hand-coins","hand-deposit","hand-eye","hand-fist","hand-grabbing","hand-heart","hand-palm","hand-peace","hand-pointing","hand-soap","hand-swipe-left","hand-swipe-right","hand-tap","hand-waving","hand-withdraw","handbag","handbag-simple","hands-clapping","hands-praying","handshake","hard-drive","hard-drives","hard-hat","hash","hash-straight","head-circuit","headlights","headphones","headset","heart","heart-break","heart-half","heart-straight","heart-straight-break","heartbeat","hexagon","high-definition","high-heel","highlighter","highlighter-circle","hockey","hoodie","horse","hospital","hourglass","hourglass-high","hourglass-low","hourglass-medium","hourglass-simple","hourglass-simple-high","hourglass-simple-low","hourglass-simple-medium","house","house-line","house-simple","hurricane","ice-cream","identification-badge","identification-card","image","image-broken","image-square","images","images-square","infinity","info","instagram-logo","intersect","intersect-square","intersect-three","intersection","invoice","island","jar","jar-label","jeep","joystick","kanban","key","key-return","keyboard","keyhole","knife","ladder","ladder-simple","lamp","lamp-pendant","laptop","lasso","lastfm-logo","layout","leaf","lectern","lego","lego-smiley","lemniscate","less-than","less-than-or-equal","letter-circle-h","letter-circle-p","letter-circle-v","lifebuoy","lightbulb","lightbulb-filament","lighthouse","lightning","lightning-a","lightning-slash","line-segment","line-segments","line-vertical","link","link-break","link-simple","link-simple-break","link-simple-horizontal","link-simple-horizontal-break","linkedin-logo","linktree-logo","linux-logo","list","list-bullets","list-checks","list-dashes","list-heart","list-magnifying-glass","list-numbers","list-plus","list-star","lock","lock-key","lock-key-open","lock-laminated","lock-laminated-open","lock-open","lock-simple","lock-simple-open","lockers","log","magic-wand","magnet","magnet-straight","magnifying-glass","magnifying-glass-minus","magnifying-glass-plus","mailbox","map-pin","map-pin-area","map-pin-line","map-pin-plus","map-pin-simple","map-pin-simple-area","map-pin-simple-line","map-trifold","markdown-logo","marker-circle","martini","mask-happy","mask-sad","mastodon-logo","math-operations","matrix-logo","medal","medal-military","medium-logo","megaphone","megaphone-simple","member-of","memory","messenger-logo","meta-logo","meteor","metronome","microphone","microphone-slash","microphone-stage","microscope","microsoft-excel-logo","microsoft-outlook-logo","microsoft-powerpoint-logo","microsoft-teams-logo","microsoft-word-logo","minus","minus-circle","minus-square","money","money-wavy","monitor","monitor-arrow-up","monitor-play","moon","moon-stars","moped","moped-front","mosque","motorcycle","mountains","mouse","mouse-left-click","mouse-middle-click","mouse-right-click","mouse-scroll","mouse-simple","music-note","music-note-simple","music-notes","music-notes-minus","music-notes-plus","music-notes-simple","navigation-arrow","needle","network","network-slash","network-x","newspaper","newspaper-clipping","not-equals","not-member-of","not-subset-of","not-superset-of","notches","note","note-blank","note-pencil","notebook","notepad","notification","notion-logo","nuclear-plant","number-circle-eight","number-circle-five","number-circle-four","number-circle-nine","number-circle-one","number-circle-seven","number-circle-six","number-circle-three","number-circle-two","number-circle-zero","number-eight","number-five","number-four","number-nine","number-one","number-seven","number-six","number-square-eight","number-square-five","number-square-four","number-square-nine","number-square-one","number-square-seven","number-square-six","number-square-three","number-square-two","number-square-zero","number-three","number-two","number-zero","numpad","nut","ny-times-logo","octagon","office-chair","onigiri","open-ai-logo","option","orange","orange-slice","oven","package","paint-brush","paint-brush-broad","paint-brush-household","paint-bucket","paint-roller","palette","panorama","pants","paper-plane","paper-plane-right","paper-plane-tilt","paperclip","paperclip-horizontal","parachute","paragraph","parallelogram","park","password","path","patreon-logo","pause","pause-circle","paw-print","paypal-logo","peace","pen","pen-nib","pen-nib-straight","pencil","pencil-circle","pencil-line","pencil-ruler","pencil-simple","pencil-simple-line","pencil-simple-slash","pencil-slash","pentagon","pentagram","pepper","percent","person","person-arms-spread","person-simple","person-simple-bike","person-simple-circle","person-simple-hike","person-simple-run","person-simple-ski","person-simple-snowboard","person-simple-swim","person-simple-tai-chi","person-simple-throw","person-simple-walk","perspective","phone","phone-call","phone-disconnect","phone-incoming","phone-list","phone-outgoing","phone-pause","phone-plus","phone-slash","phone-transfer","phone-x","phosphor-logo","pi","piano-keys","picnic-table","picture-in-picture","piggy-bank","pill","ping-pong","pint-glass","pinterest-logo","pinwheel","pipe","pipe-wrench","pix-logo","pizza","placeholder","planet","plant","play","play-circle","play-pause","playlist","plug","plug-charging","plugs","plugs-connected","plus","plus-circle","plus-minus","plus-square","poker-chip","police-car","polygon","popcorn","popsicle","potted-plant","power","prescription","presentation","presentation-chart","printer","prohibit","prohibit-inset","projector-screen","projector-screen-chart","pulse","push-pin","push-pin-simple","push-pin-simple-slash","push-pin-slash","puzzle-piece","qr-code","question","question-mark","queue","quotes","rabbit","racquet","radical","radio","radio-button","radioactive","rainbow","rainbow-cloud","ranking","read-cv-logo","receipt","receipt-x","record","rectangle","rectangle-dashed","recycle","reddit-logo","repeat","repeat-once","replit-logo","resize","rewind","rewind-circle","road-horizon","robot","rocket","rocket-launch","rows","rows-plus-bottom","rows-plus-top","rss","rss-simple","rug","ruler","sailboat","scales","scan","scan-smiley","scissors","scooter","screencast","screwdriver","scribble","scribble-loop","scroll","seal","seal-check","seal-percent","seal-question","seal-warning","seat","seatbelt","security-camera","selection","selection-all","selection-background","selection-foreground","selection-inverse","selection-plus","selection-slash","shapes","share","share-fat","share-network","shield","shield-check","shield-checkered","shield-chevron","shield-plus","shield-slash","shield-star","shield-warning","shipping-container","shirt-folded","shooting-star","shopping-bag","shopping-bag-open","shopping-cart","shopping-cart-simple","shovel","shower","shrimp","shuffle","shuffle-angular","shuffle-simple","sidebar","sidebar-simple","sigma","sign-in","sign-out","signature","signpost","sim-card","siren","sketch-logo","skip-back","skip-back-circle","skip-forward","skip-forward-circle","skull","skype-logo","slack-logo","sliders","sliders-horizontal","slideshow","smiley","smiley-angry","smiley-blank","smiley-meh","smiley-melting","smiley-nervous","smiley-sad","smiley-sticker","smiley-wink","smiley-x-eyes","snapchat-logo","sneaker","sneaker-move","snowflake","soccer-ball","sock","solar-panel","solar-roof","sort-ascending","sort-descending","soundcloud-logo","spade","sparkle","speaker-hifi","speaker-high","speaker-low","speaker-none","speaker-simple-high","speaker-simple-low","speaker-simple-none","speaker-simple-slash","speaker-simple-x","speaker-slash","speaker-x","speedometer","sphere","spinner","spinner-ball","spinner-gap","spiral","split-horizontal","split-vertical","spotify-logo","spray-bottle","square","square-half","square-half-bottom","square-logo","square-split-horizontal","square-split-vertical","squares-four","stack","stack-minus","stack-overflow-logo","stack-plus","stack-simple","stairs","stamp","standard-definition","star","star-and-crescent","star-four","star-half","star-of-david","steam-logo","steering-wheel","steps","stethoscope","sticker","stool","stop","stop-circle","storefront","strategy","stripe-logo","student","subset-of","subset-proper-of","subtitles","subtitles-slash","subtract","subtract-square","subway","suitcase","suitcase-rolling","suitcase-simple","sun","sun-dim","sun-horizon","sunglasses","superset-of","superset-proper-of","swap","swatches","swimming-pool","sword","synagogue","syringe","t-shirt","table","tabs","tag","tag-chevron","tag-simple","target","taxi","tea-bag","telegram-logo","television","television-simple","tennis-ball","tent","terminal","terminal-window","test-tube","text-a-underline","text-aa","text-align-center","text-align-justify","text-align-left","text-align-right","text-b","text-bolder","text-columns","text-h","text-h-five","text-h-four","text-h-one","text-h-six","text-h-three","text-h-two","text-indent","text-italic","text-outdent","text-strikethrough","text-subscript","text-superscript","text-t","text-t-slash","text-underline","textbox","thermometer","thermometer-cold","thermometer-hot","thermometer-simple","threads-logo","three-d","thumbs-down","thumbs-up","ticket","tidal-logo","tiktok-logo","tilde","timer","tip-jar","tipi","tire","toggle-left","toggle-right","toilet","toilet-paper","toolbox","tooth","tornado","tote","tote-simple","towel","tractor","trademark","trademark-registered","traffic-cone","traffic-sign","traffic-signal","train","train-regional","train-simple","tram","translate","trash","trash-simple","tray","tray-arrow-down","tray-arrow-up","treasure-chest","tree","tree-evergreen","tree-palm","tree-structure","tree-view","trend-down","trend-up","triangle","triangle-dashed","trolley","trolley-suitcase","trophy","truck","truck-trailer","tumblr-logo","twitch-logo","twitter-logo","umbrella","umbrella-simple","union","unite","unite-square","upload","upload-simple","usb","user","user-check","user-circle","user-circle-check","user-circle-dashed","user-circle-gear","user-circle-minus","user-circle-plus","user-focus","user-gear","user-list","user-minus","user-plus","user-rectangle","user-sound","user-square","user-switch","users","users-four","users-three","van","vault","vector-three","vector-two","vibrate","video","video-camera","video-camera-slash","video-conference","vignette","vinyl-record","virtual-reality","virus","visor","voicemail","volleyball","wall","wallet","warehouse","warning","warning-circle","warning-diamond","warning-octagon","washing-machine","watch","wave-sawtooth","wave-sine","wave-square","wave-triangle","waveform","waveform-slash","waves","webcam","webcam-slash","webhooks-logo","wechat-logo","whatsapp-logo","wheelchair","wheelchair-motion","wifi-high","wifi-low","wifi-medium","wifi-none","wifi-slash","wifi-x","wind","windmill","windows-logo","wine","wrench","x","x-circle","x-logo","x-square","yarn","yin-yang","youtube-logo"];
let COLORS = []; // filled from WASM colors_json() at boot

// container -> CSS shape (clip-path or border-radius)
const SHAPE = {
  shield:"clip:polygon(50% 0,100% 14%,100% 60%,50% 100%,0 60%,0 14%)",
  circle:"r:50%", lozenge:"r:46%/34%", oval:"r:50%",
  crest:"clip:polygon(8% 0,92% 0,100% 70%,50% 100%,0 70%)",
  banner:"clip:polygon(0 0,100% 0,100% 78%,50% 100%,0 78%)",
  hex:"clip:polygon(25% 3%,75% 3%,100% 50%,75% 97%,25% 97%,0 50%)",
  rounded_sq:"r:26%", diamond:"clip:polygon(50% 0,100% 50%,50% 100%,0 50%)",
  badge:"clip:polygon(50% 0,61% 10%,76% 7%,80% 22%,95% 30%,89% 45%,98% 58%,86% 68%,88% 84%,72% 86%,63% 99%,50% 91%,37% 99%,28% 86%,12% 84%,14% 68%,2% 58%,11% 45%,5% 30%,20% 22%,24% 7%,39% 10%)",
  ribbon:"clip:polygon(0 18%,100% 18%,100% 82%,50% 100%,0 82%)",
  seal:"r:50%",
};
const VERTICALS = [
  {id:"skincare",label:"Skincare",ic:"ph-drop",sub:"creams · serums"},
  {id:"cookware",label:"Cookware",ic:"ph-cooking-pot",sub:"pans · tools"},
  {id:"software",label:"Software",ic:"ph-cursor",sub:"apps · tools"},
  {id:"apparel",label:"Apparel",ic:"ph-coat-hanger",sub:"basics · wear"},
  {id:"beverages",label:"Beverages",ic:"ph-wine",sub:"drinks · brews"},
  {id:"beauty",label:"Beauty",ic:"ph-paint-brush-household",sub:"makeup · color"},
  {id:"wellness",label:"Wellness",ic:"ph-pill",sub:"supplements"},
  {id:"home",label:"Home",ic:"ph-house",sub:"decor · goods"},
  {id:"pet",label:"Pet",ic:"ph-paw-print",sub:"treats · gear"},
  {id:"snacks",label:"Snacks",ic:"ph-cookie",sub:"food · treats"},
];

/* ===== rnd: pure presentation pick (which deterministic WASM brand to roll) ===== */
const rnd=a=>a[Math.floor(Math.random()*a.length)];

/* ===== state (the recipe + identity) ===== */
let R = { vertical:"cookware", name:"Hearth & Hew", glyph:"whisk", container:"squircle", c1:49, c2:69, c3:48, font:"fraunces", layout:"stacked" };
let step = 0;
let hasSave = false;
const rgb = a => `rgb(${a[0]},${a[1]},${a[2]})`;
const glyphsFor = v => JSON.parse(glyphs_for(v)); // suggested glyph ids from WASM
const glyphIc = id => "ph-"+id;

/* ===== live logo render (mirrors Logo.resolve) ===== */
const col = i => rgb(COLORS[i-1]);  // 1-based recipe color id
function renderLogo(){
  const logo = document.getElementById('logo');
  logo.className = "logo stacked";   // one clean arrangement (layout picker removed)
  const fontcls = FONTS.find(f=>f.id===R.font).cls;
  logo.innerHTML =
    `<div class="crest" style="border-radius:28%;background:${col(R.c1)}"><i class="ph-fill ${glyphIc(R.glyph)}" style="color:${col(R.c2)}"></i></div>`+
    `<div class="wordmark ${fontcls}" style="color:${col(R.c3)}">${R.name}</div>`;
  const vdef = VERTICALS.find(v=>v.id===R.vertical);
  document.getElementById('pvvert').textContent = vdef.label.toLowerCase();
  document.getElementById('vicon').className = 'ph-fill ' + vdef.ic;
  document.getElementById('palrow').innerHTML = [R.c1,R.c2,R.c3].map(i=>`<span style="background:${col(i)}"></span>`).join('');
}

/* ===== steps ===== */
const STEPS = [
  {key:"vertical",title:"Pick your industry",hint:"Tap one — we'll spin up a fresh themed brand you can tweak. Tap again to re-roll it.",render:()=>
    `<div class="qs-row"><button class="btn qs-btn" onclick="quickStart()"><i class="ph-bold ph-lightning"></i> Quick start — skip setup</button></div>
    <div class="qs-or">or pick your industry to customize</div>
    <div class="grid g4">`+VERTICALS.map(v=>
      `<div class="opt ${R.vertical===v.id?'sel':''}" onclick="pickIndustry('${v.id}')">
        <i class="ph-fill ${v.ic}"></i><span class="lab">${v.label}</span><span class="sub">${v.sub}</span></div>`).join('')+`</div>`},
  {key:"name",title:"Name the brand",hint:"Generate a name or type your own.",render:()=>
    `<div class="namebox">
      <input class="namebig" id="nameinput" value="${R.name.replace(/"/g,'&quot;')}" oninput="setName(this.value)" maxlength="22">
      <button class="reroll" onclick="rollName()"><i class="ph-bold ph-arrows-clockwise"></i> Roll a name</button>
      <div class="namehint">Tip: short names read best on a card.</div>
    </div>`},
  {key:"glyph",title:"Pick your logo",hint:"Suggested for your industry — or search the full logo library.",render:()=>
    `<div class="searchbar"><i class="ph-fill ph-magnifying-glass"></i>
       <input id="iconsearch" placeholder="search ${ICONS.length} logos…" oninput="searchIcons(this.value)" value="${iconQuery}">
     </div>
     <div class="grid g6" id="iconresults"></div>
     <div id="suggested">
       <div class="suglabel">SUGGESTED</div>
       <div class="grid g6">`+glyphsFor(R.vertical).map(id=>
        `<div class="opt optsm ${R.glyph===id?'sel':''}" onclick="pick('glyph','${id}')"><i class="ph-fill ph-${id}"></i></div>`).join('')+`</div>
     </div>`,
   after:()=>searchIcons(iconQuery)},
  {key:"palette",title:"Spin your colors",hint:"Scroll each wheel — background, icon, and text color. Hit Surprise to shuffle all three.",render:()=>
    `<div class="spinrow">
       ${spinnerHTML('c1','BG','background')}
       ${spinnerHTML('c2','ICON','icon')}
       ${spinnerHTML('c3','TEXT','text')}
     </div>`,
   after:()=>{ ['c1','c2','c3'].forEach(initSpinner); }},
  {key:"font",title:"Set the type",hint:"The font for your brand name.",render:()=>
    `<div class="grid g3">`+FONTS.map(f=>
      `<div class="opt ${R.font===f.id?'sel':''}" onclick="pick('font','${f.id}')">
        <span class="${f.cls}" style="font-size:26px;font-weight:800">Ag</span><span class="lab">${f.label}</span></div>`).join('')+`</div>`},
  {key:"sign",title:"Your brand is ready",hint:"This is your studio name — progress saves under this brand.",render:()=>
    `<div class="signwrap">
      <h2>${R.name}</h2>
      <p>A new ${VERTICALS.find(v=>v.id===R.vertical).label.toLowerCase()} brand. From here you'll take your first client.</p>
      <div class="signrow">
        <div><span>INDUSTRY</span><b>${VERTICALS.find(v=>v.id===R.vertical).label}</b></div>
        <div><span>ICON</span><b><i class="ph-fill ph-${R.glyph}"></i></b></div>
        <div><span>COLORS</span><b class="swrow"><s style="background:${col(R.c1)}"></s><s style="background:${col(R.c2)}"></s><s style="background:${col(R.c3)}"></s></b></div>
      </div>
    </div>`},
];

/* ===== color spinners ===== */
const SW_H = 44;
function spinnerHTML(field, label, role){
  const sws = COLORS.map((c,i)=>`<div class="sw"><div style="background:rgb(${c[0]},${c[1]},${c[2]})"></div></div>`).join('');
  return `<div class="spincol">
    <div class="slabel">${label}</div><div class="srole">${role}</div>
    <div class="spinner"><div class="reel" id="reel_${field}" data-field="${field}">${sws}</div><div class="selband"></div></div>
    <div class="spinarrows">
      <button onclick="nudge('${field}',-1)"><i class="ph-bold ph-caret-up"></i></button>
      <button onclick="nudge('${field}',1)"><i class="ph-bold ph-caret-down"></i></button></div>
  </div>`;
}
function initSpinner(field){
  const reel = document.getElementById('reel_'+field);
  reel.scrollTop = (R[field]-1)*SW_H;           // center current color
  let t;
  reel.onscroll = ()=>{ clearTimeout(t); t=setTimeout(()=>{
    const idx = Math.round(reel.scrollTop/SW_H)+1;
    if(idx!==R[field]){ R[field]=Math.max(1,Math.min(COLORS.length,idx)); renderLogo(); }
  }, 60); };
}
function nudge(field, d){
  R[field]=Math.max(1,Math.min(COLORS.length,R[field]+d));
  const reel=document.getElementById('reel_'+field);
  reel.scrollTo({top:(R[field]-1)*SW_H, behavior:'smooth'});
  renderLogo();
}

function renderStep(){
  const s = STEPS[step];
  document.getElementById('stepnum').textContent = `STEP ${step+1} OF ${STEPS.length}`;
  document.getElementById('steptitle').textContent = s.title;
  document.getElementById('stephint').textContent = s.hint;
  document.getElementById('stepbody').innerHTML = s.render();
  if(s.after) s.after();
  document.getElementById('dots').innerHTML = STEPS.map((_,i)=>
    `<div class="dot ${i<step?'done':i===step?'active':''}" onclick="jump(${i})"></div>`).join('');
  document.getElementById('backbtn').style.display = (step > 0 || hasSave) ? '' : 'none';
  const nb = document.getElementById('nextbtn');
  if(step===STEPS.length-1){ nb.textContent="Build your team →"; nb.className="btn"; }
  else { nb.textContent="Next"; nb.className="btn sec"; }
  renderLogo();
}
function pick(field,val){ R[field]=val; renderStep(); }

// picking an industry spins up a fresh themed brand (name + mark + colors)
function pickIndustry(id){
  const b = JSON.parse(random_brand(newSeed(), id));  // fresh themed brand from WASM
  R.vertical = id; R.name = b.name; R.glyph = b.glyph;
  R.c1 = b.c1; R.c2 = b.c2; R.c3 = b.c3;
  renderStep();
}

// full-library icon search (Suggested stays above; results cap for DOM)
let iconQuery = "";
function searchIcons(q){
  iconQuery = q;
  const el = document.getElementById('iconresults'); if(!el) return;
  const sug = document.getElementById('suggested');
  const ql = q.trim().toLowerCase();
  if(!ql){ el.innerHTML=''; if(sug) sug.style.display=''; return; }   // empty -> show suggested
  if(sug) sug.style.display='none';                                    // searching -> results take over
  const list = ICONS.filter(n=>n.includes(ql));
  const shown = list.slice(0,120);
  el.innerHTML = shown.length
    ? shown.map(n=>`<div class="opt optsm ${R.glyph===n?'sel':''}" onclick="pick('glyph','${n}')" title="${n}"><i class="ph-fill ph-${n}"></i></div>`).join('')
      + (list.length>120?`<div class="noresults">+${list.length-120} more — keep typing to narrow</div>`:'')
    : `<div class="noresults">no logos match "${q}"</div>`;
}
function go(d){
  if(step===STEPS.length-1 && d>0){ launch(); return; }
  if(step===0 && d<0){ location.href='index.html'; return; }
  step=Math.max(0,Math.min(STEPS.length-1,step+d)); renderStep();
}
function jump(i){ step=i; renderStep(); }
function surprise(){
  const vert = rnd(VERTICALS).id;                       // pick a lane...
  const b = JSON.parse(random_brand(newSeed(), vert));  // ...WASM rolls the whole recipe
  R.vertical = b.vertical; R.name = b.name; R.glyph = b.glyph;
  R.container = "squircle";
  R.c1 = b.c1; R.c2 = b.c2; R.c3 = b.c3;
  R.font = b.font; R.layout = b.layout;
  renderStep();
}
async function quickStart(){ surprise(); await launch(); }
async function launch(){
  const hex = i => { const c = COLORS[i-1]; return `rgb(${c[0]},${c[1]},${c[2]})`; };
  const save = {
    brand: R, week: 1, created: Date.now(),
    display: { bg: hex(R.c1), mark: hex(R.c2), ink: hex(R.c3), glyph: R.glyph, font: R.font, name: R.name }
  };
  await writeSave(save)
  location.href = "team-designer.html";
}
/* ===== bootstrap: gate the whole UI on the WASM init ===== */
const newSeed = () => (Math.random()*0x100000000) >>> 0;
function rollName(){ R.name = roll_name(newSeed(), R.vertical); const el=document.getElementById('nameinput'); if(el) el.value=R.name; renderLogo(); }
function setName(v){ R.name = v; renderLogo(); }
window.pickIndustry=pickIndustry; window.pick=pick; window.surprise=surprise;
window.go=go; window.jump=jump; window.nudge=nudge; window.searchIcons=searchIcons;
window.rollName=rollName; window.setName=setName; window.quickStart=quickStart;
(async () => {
  await init();                                 // <- nothing renders until WASM is ready
  COLORS = JSON.parse(colors_json());           // spinner reel + col() pool, from WASM
  const existing = await readSave().catch(() => null);
  hasSave = !!(existing && existing.brand && existing.brand.name);
  const b = JSON.parse(random_brand(newSeed(), R.vertical));
  R.name=b.name; R.glyph=b.glyph; R.container="squircle";
  R.c1=b.c1; R.c2=b.c2; R.c3=b.c3; R.font=b.font; R.layout=b.layout;
  renderStep();
})();
