-- [ACTIVE] BrainrotAnimations
--[[
	BrainrotAnimations — stand Idle animation asset IDs (rbxassetid numbers).
	No ReplicatedStorage.BrainrotAnimations folder required.
--]]

local M = {}

M.IDLE = {
	["NoobiniPizzanini"] = 102012699059338,
	["LiriliLarila"] = 81609136535551,
	["TimCheese"] = 123573016645821,
	["FluriFlura"] = 123218276110599,
	["TalpaDiFero"] = 138917924626970,
	["SvininaBombardino"] = 125593597742534,
	["PipiKiwi"] = 118965854009210,
	["TrippiTroppi"] = 89942627022167,
	["GangsterFootera"] = 113613781576696,
	["BanditoBobrito"] = 126070331721857,
	["BonecaAmbalabu"] = 82452647163145,
	["CactoHipopotamo"] = 135911680665314,
	["CappuccinoAssassino"] = 129489677529107,
	["BrrBrrPatapim"] = 95574696138139,
	["AvocadiniAntilopini"] = 135835463148121,
	["TrulimeroTrulicina"] = 95344411878418,
	["BambiniCrostini"] = 124125468292863,
	["BananitoDelfinito"] = 125289792215053,
	["AvocadiniGuffo"] = 136035236790762,
	["BrrBicusDicus"] = 138004767178926,
	["BurbalolliLulilolli"] = 139069972938830,
	-- Legacy typo spelling
	["BurbalolliLuilolli"] = 139069972938830,
	["BalerinaCapucina"] = 137174932392010,
	["SalaminoPinguino"] = 103221813247265,
	["ChimpanziniBananini"] = 103850827042553,
	["TirilikalikaTirilikalako"] = 114435202691394,
	["FrigoCamelo"] = 121083935379665,
	["OrangutiniAnanassini"] = 101569991072351,
	["RhinoToasterino"] = 91625013215976,
	["BombardinoCrocodilo"] = 101177565866255,
	["GiraffaCelestre"] = 89589331408965,
	["ElefantoCocofanto"] = 104777141796214,
	["OdinDinDinDun"] = 97694447453800,
	["Alessio"] = 115451866655473,
	["BalerinoLololo"] = 110328700571997,
	["Pakrahmatmamat"] = 137225053165641,
	["TrippiTroppiTroppaTrippa"] = 89942627022167,
	["TatatataSahur"] = 126404281186060,
	["TikTakSahur"] = 99536792676186,
	["TungTungSahur"] = 74769883499979,
	["Madung"] = 132522421516253,
	["Mateo"] = 72102620663010,
	["Pepe"] = 121752044142136,
	["Ben"] = 90464488096681,
	["PipiPotato"] = 123381169868429,
	["PotHotspot"] = 82905925784072,
	["QuesadillaCrocodila"] = 79140200793070,
	["SwagSoda"] = 134835429409859,
	["SmurfCat"] = 101019514082475,
	["Trollface"] = 93455639134229,
	["SigmaBoy"] = 98932427267950,
	["HappyBananaMeme"] = 129386839781990,
	["HappyBananaCat"] = 99784155863718,
	["NyanCat"] = 95823671570823,
	["YesMyExamine"] = 112727063924726,
	["NooMyExamine"] = 86734855469451,
	["EsokSekolah"] = 95644827307099,
	["ChillinChili"] = 126506419501742,
	["Garamarama"] = 109717090582871,
	["KetupatKepat"] = 133065781774704,
	["KetchuruAndMusturu"] = 73191297915004,
	["Lerulerulerule"] = 123943890223566,
	["BlueberrinniOctopusini"] = 82220253311415,
	["BombombiniGusini"] = 140346122622707,
	["CachorritoMelonito"] = 92713796382434,
	["CavalloVirtuoso"] = 81382538231258,
	["ChicleteiraBicicleteira"] = 124438716143060,
	["ChicleteirinaBicicleteirina"] = 90486004309505,
	["DragonCannelloni"] = 119873501348401,
	["GanganzelliTrulala"] = 91897763759294,
	["GorilloWatermelondrillo"] = 120117041392420,
	["GraipusMedussi"] = 87183272587332,
	["LioneloCactuseli"] = 104017098370613,
	["PandacciniBananini"] = 91168888565689,
	["TricTracBarabum"] = 93169378235673,
	["TralaleroTralala"] = 87451813241215,
	["TralalitaTralala"] = 90538512251644,
	["Tralaledon"] = 126693039227818,
	["TriplitoTralaleritos"] = 131315185785160,
	["ZibraZubraZibralini"] = 133226970374441,
	["GlorboFruttodrillo"] = 122885551499937,
	["TigroligreFrutonni"] = 78837925460143,
	["NuclearoDinosauro"] = 109077883594025,
	["ChefCrabracadabra"] = 103444638323844,
	["EspressoSignora"] = 110967693075272,
	["LaGrandeCombination"] = 115278429022206,
	["Illuminati"] = 126157794764630,
	["OrcaleroOrcala"] = 95017447097243,
	["StrawberryElephant"] = 78191609568378,
	["SkibidiToilet"] = 70433677306335,
	["Meowl"] = 132340374240030,
	["Pakrahmatmatina"] = 88840139751110,
	["AgarriniLaPallini"] = 85106055706353,
	["TorrtuginniDragonfrutini"] = 82270750357008,
	["LaVaccaSaturnoSaturnita"] = 121799740579572,
	["KarkerkarKurkur"] = 78121103736130,
	["JobJobJobSahur"] = 112927706638024,
	["67"] = 71707443570233,
	["69"] = 105128351187658,
	["StrawberrelliFlamingelli"] = 84579135400209,
	["LosTralalelitos"] = 110780058827589,
}

local animCache: { [string]: Animation } = {}

function M.getIdleAnimationId(brainrotName: string): number?
	return M.IDLE[brainrotName]
end

function M.getIdleAnimation(brainrotName: string): Animation?
	local assetId = M.IDLE[brainrotName]
	if not assetId then
		return nil
	end
	local cached = animCache[brainrotName]
	if cached then
		return cached
	end
	local anim = Instance.new("Animation")
	anim.Name = "Idle"
	anim.AnimationId = "rbxassetid://" .. tostring(assetId)
	animCache[brainrotName] = anim
	return anim
end

return M
