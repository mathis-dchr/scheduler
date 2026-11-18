/**
 * Scheduler « 90/10 » : voir sched_time_90.h
 */

#include "srsenb/hdr/stack/mac/schedulers/sched_time_90.h"
#include "srsenb/hdr/stack/mac/sched_ue_ctrl/sched_ue_cell.h"
#include "srsran/phy/dft/dft_precoding.h"
#include <algorithm>
#include <cmath>
#include <cstdlib>

namespace srsenb {

sched_time_90::sched_time_90(const sched_cell_params_t& cell_params_, const sched_interface::sched_args_t& sched_args)
{
  cc_cfg = &cell_params_;
  // Part du dernier UE lue dans scheduler.policy_args si c'est un nombre entre 0 et 1, sinon 0.9
  const std::string& args = sched_args.sched_policy_args;
  if (not args.empty()) {
    char* fin = nullptr;
    float v   = std::strtof(args.c_str(), &fin);
    if (fin != args.c_str() and v > 0 and v < 1) {
      part_nouveau = v;
    }
  }
  logger.info("SCHED90: le dernier UE arrive recoit %.0f%% des ressources", part_nouveau * 100);
}

/*****************************************************************
 *                    Ordre d'arrivée des UE
 *****************************************************************/

void sched_time_90::update_arrivals(sched_ue_list& ue_db)
{
  // Oublier les UE qui ont quitté la cellule
  for (auto it = arrivee.begin(); it != arrivee.end();) {
    if (not ue_db.contains(it->first)) {
      it = arrivee.erase(it);
    } else {
      ++it;
    }
  }
  // Numéroter les nouveaux UE dans l'ordre où ils apparaissent
  for (auto& u : ue_db) {
    if (arrivee.count(u.first) == 0) {
      arrivee[u.first] = compteur++;
      logger.info("SCHED90: nouvel UE rnti=0x%x, il devient prioritaire", u.first);
    }
  }
}

uint16_t sched_time_90::newest_rnti() const
{
  uint16_t rnti    = 0;
  uint64_t max_num = 0;
  bool     trouve  = false;
  for (const auto& a : arrivee) {
    if (not trouve or a.second > max_num) {
      rnti    = a.first;
      max_num = a.second;
      trouve  = true;
    }
  }
  return rnti;
}

std::vector<uint16_t> sched_time_90::others_rotated(uint32_t tti) const
{
  // Les autres UE, triés par ordre d'arrivée
  std::vector<std::pair<uint64_t, uint16_t> > tri;
  uint16_t                                    nouveau = newest_rnti();
  for (const auto& a : arrivee) {
    if (a.first != nouveau) {
      tri.emplace_back(a.second, a.first);
    }
  }
  std::sort(tri.begin(), tri.end());
  std::vector<uint16_t> liste;
  for (const auto& t : tri) {
    liste.push_back(t.second);
  }
  // Rotation à chaque TTI : chacun passe en premier à son tour (partage équitable des 10 %)
  if (not liste.empty()) {
    std::rotate(liste.begin(), liste.begin() + (tti % liste.size()), liste.end());
  }
  return liste;
}

/*****************************************************************
 *                         Downlink
 *****************************************************************/

void sched_time_90::sched_dl_users(sched_ue_list& ue_db, sf_sched* tti_sched)
{
  if (ue_db.empty()) {
    return;
  }
  update_arrivals(ue_db);

  // 1. Retransmissions HARQ d'abord, pour tous les UE
  for (auto& u : ue_db) {
    sched_ue&           user = *u.second;
    const dl_harq_proc* h    = get_dl_retx_harq(user, tti_sched);
    if (h != nullptr) {
      try_dl_retx_alloc(*tti_sched, user, *h);
    }
  }

  // 2. Partage des RBG de la cellule : 90 % pour le dernier UE, 10 % pour les autres
  uint32_t nof_rbgs       = tti_sched->get_dl_mask().size();
  uint32_t budget_nouveau = std::max(1u, (uint32_t)std::lround(part_nouveau * nof_rbgs));
  uint32_t budget_autres  = nof_rbgs > budget_nouveau ? nof_rbgs - budget_nouveau : 0;

  // 3. Le dernier UE arrivé : jusqu'à 90 %
  uint16_t rnti_nouveau = newest_rnti();
  if (ue_db.contains(rnti_nouveau)) {
    uint32_t used = try_dl_newtx_capped(*tti_sched, *ue_db[rnti_nouveau], budget_nouveau);
    logger.debug("SCHED90: DL rnti=0x%x (dernier) %u/%u RBG", rnti_nouveau, used, budget_nouveau);
  }

  // 4. Les autres : se partagent les 10 % à tour de rôle
  uint32_t reste = budget_autres;
  for (uint16_t rnti : others_rotated(tti_sched->get_tti_tx_dl().to_uint())) {
    if (reste == 0) {
      break;
    }
    if (not ue_db.contains(rnti)) {
      continue;
    }
    uint32_t used = try_dl_newtx_capped(*tti_sched, *ue_db[rnti], reste);
    reste -= std::min(used, reste);
    if (used > 0) {
      logger.debug("SCHED90: DL rnti=0x%x (autre) %u RBG", rnti, used);
    }
  }
}

uint32_t sched_time_90::try_dl_newtx_capped(sf_sched& tti_sched, sched_ue& user, uint32_t max_rbgs)
{
  if (max_rbgs == 0 or user.enb_to_ue_cc_idx(cc_cfg->enb_cc_idx) < 0) {
    return 0;
  }
  const dl_harq_proc* h = get_dl_newtx_harq(user, &tti_sched);
  if (h == nullptr) {
    return 0;
  }
  srsran::interval<uint32_t> req_bytes = user.get_requested_dl_bytes(tti_sched.get_enb_cc_idx());
  if (req_bytes.stop() == 0) {
    return 0;
  }

  // Masque limité : seuls les max_rbgs premiers RBG libres restent disponibles pour cet UE
  rbgmask_t limite = tti_sched.get_dl_mask();
  uint32_t  libres = 0;
  for (uint32_t i = 0; i < limite.size(); ++i) {
    if (not limite.test(i)) {
      if (libres < max_rbgs) {
        libres++;
      } else {
        limite.set(i);
      }
    }
  }
  if (limite.all()) {
    return 0;
  }

  // Même calcul que l'allocation gloutonne d'origine, mais sur le masque limité
  sched_ue_cell* ue_cell = user.find_ue_carrier(tti_sched.get_enb_cc_idx());
  if (ue_cell == nullptr) {
    return 0;
  }
  tbs_info  tb;
  rbgmask_t opt_mask;
  if (not find_optimal_rbgmask(
          *ue_cell, tti_sched.get_tti_tx_dl(), limite, user.get_dci_format(), req_bytes, tb, opt_mask)) {
    return 0;
  }
  alloc_result ret = tti_sched.alloc_dl_user(&user, opt_mask, h->get_id());
  if (ret == alloc_result::no_cch_space) {
    logger.info("SCHED90: pas de place PDCCH pour rnti=0x%x en DL", user.get_rnti());
  }
  return ret == alloc_result::success ? opt_mask.count() : 0;
}

/*****************************************************************
 *                         Uplink
 *****************************************************************/

void sched_time_90::sched_ul_users(sched_ue_list& ue_db, sf_sched* tti_sched)
{
  if (ue_db.empty()) {
    return;
  }
  update_arrivals(ue_db);

  // 1. Retransmissions HARQ d'abord, pour tous les UE
  for (auto& u : ue_db) {
    sched_ue&           user = *u.second;
    const ul_harq_proc* h    = get_ul_retx_harq(user, tti_sched);
    if (h != nullptr) {
      try_ul_retx_alloc(*tti_sched, user, *h);
    }
  }

  // 2. Partage des PRB : 90 % pour le dernier UE, 10 % pour les autres
  uint32_t nof_prbs       = tti_sched->get_ul_mask().size();
  uint32_t budget_nouveau = std::max(1u, (uint32_t)std::lround(part_nouveau * nof_prbs));
  uint32_t budget_autres  = nof_prbs > budget_nouveau ? nof_prbs - budget_nouveau : 0;

  // 3. Le dernier UE arrivé
  uint16_t rnti_nouveau = newest_rnti();
  if (ue_db.contains(rnti_nouveau)) {
    try_ul_newtx_capped(*tti_sched, *ue_db[rnti_nouveau], budget_nouveau);
  }

  // 4. Les autres, à tour de rôle
  uint32_t reste = budget_autres;
  for (uint16_t rnti : others_rotated(tti_sched->get_tti_tx_ul().to_uint())) {
    if (reste == 0) {
      break;
    }
    if (not ue_db.contains(rnti)) {
      continue;
    }
    uint32_t used = try_ul_newtx_capped(*tti_sched, *ue_db[rnti], reste);
    reste -= std::min(used, reste);
  }
}

uint32_t sched_time_90::try_ul_newtx_capped(sf_sched& tti_sched, sched_ue& user, uint32_t max_prbs)
{
  if (max_prbs == 0 or not ul_enabled(user)) {
    return 0;
  }
  const ul_harq_proc* h = get_ul_newtx_harq(user, &tti_sched);
  if (h == nullptr) {
    return 0;
  }
  uint32_t pending_data = user.get_pending_ul_new_data(tti_sched.get_tti_tx_ul(), cc_cfg->enb_cc_idx);
  if (pending_data == 0) {
    return 0;
  }
  uint32_t     pending_rb = std::min(user.get_required_prb_ul(cc_cfg->enb_cc_idx, pending_data), max_prbs);
  prb_interval alloc      = find_contiguous_ul_prbs(pending_rb, tti_sched.get_ul_mask());
  // find_contiguous_ul_prbs peut ajuster la taille (contrainte SC-FDMA) : on revient sous le plafond
  while (not alloc.empty() and (alloc.length() > max_prbs or not srsran_dft_precoding_valid_prb(alloc.length()))) {
    alloc.resize_by(-1);
  }
  if (alloc.empty()) {
    return 0;
  }
  alloc_result ret = tti_sched.alloc_ul_user(&user, alloc);
  if (ret == alloc_result::no_cch_space) {
    logger.info("SCHED90: pas de place PDCCH pour rnti=0x%x en UL", user.get_rnti());
  }
  return ret == alloc_result::success ? alloc.length() : 0;
}

bool sched_time_90::ul_enabled(const sched_ue& user) const
{
  for (auto& cc : user.get_ue_cfg().supported_cc_list) {
    if (cc.enb_cc_idx == cc_cfg->enb_cc_idx) {
      return not cc.ul_disabled;
    }
  }
  return false;
}

} // namespace srsenb